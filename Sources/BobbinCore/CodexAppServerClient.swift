import Foundation

public final class CodexAppServerClient: @unchecked Sendable {
    public typealias JSONObject = [String: Any]
    public typealias NotificationHandler = (JSONObject) -> Void
    public typealias TerminationHandler = (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.tinyharness.app-server")
    private let codexHome: URL
    private let executableURL: URL

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var recentErrorOutput = ""
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONObject, Error>] = [:]

    public var onNotification: NotificationHandler?
    public var onTermination: TerminationHandler?

    public init(codexHome: URL, executableURL: URL? = nil) throws {
        self.codexHome = codexHome
        guard let executableURL = executableURL ?? Self.findCodexExecutable() else {
            throw HarnessError.codexNotFound
        }
        self.executableURL = executableURL
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        stateQueue.sync { process?.isRunning == true }
    }

    public func start() async throws {
        if isRunning { return }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        environment.removeValue(forKey: "OPENAI_API_KEY")
        process.environment = environment

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.stateQueue.async { self?.consumeOutput(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.stateQueue.async { self?.appendErrorOutput(text) }
        }
        process.terminationHandler = { [weak self] process in
            self?.stateQueue.async { self?.handleTermination(status: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        stateQueue.sync {
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            self.outputBuffer.removeAll(keepingCapacity: true)
            self.recentErrorOutput = ""
        }

        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "bobbin",
                    "title": "Bobbin",
                    "version": "0.1.1"
                ]
            ]
        )
        try sendNotification(method: "initialized", params: [:])
    }

    public func stop() {
        stateQueue.sync {
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            errorPipe?.fileHandleForReading.readabilityHandler = nil
            if process?.isRunning == true { process?.terminate() }
            process = nil
            inputPipe = nil
            outputPipe = nil
            errorPipe = nil
        }
    }

    public func request(method: String, params: JSONObject? = nil) async throws -> JSONObject {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                guard self.process?.isRunning == true, let input = self.inputPipe?.fileHandleForWriting else {
                    continuation.resume(throwing: HarnessError.appServerStopped(self.recentErrorOutput))
                    return
                }

                let id = self.nextID
                self.nextID += 1
                var message: JSONObject = ["id": id, "method": method]
                if let params { message["params"] = params }

                do {
                    let data = try Self.encodedLine(message)
                    self.pending[id] = continuation
                    try input.write(contentsOf: data)
                } catch {
                    self.pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func sendNotification(method: String, params: JSONObject? = nil) throws {
        try stateQueue.sync {
            guard process?.isRunning == true, let input = inputPipe?.fileHandleForWriting else {
                throw HarnessError.appServerStopped(recentErrorOutput)
            }
            var message: JSONObject = ["method": method]
            if let params { message["params"] = params }
            try input.write(contentsOf: Self.encodedLine(message))
        }
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstRange(of: Data([0x0A])) {
            let line = outputBuffer.subdata(in: outputBuffer.startIndex..<newline.lowerBound)
            outputBuffer.removeSubrange(outputBuffer.startIndex...newline.lowerBound)
            guard !line.isEmpty else { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ data: Data) {
        guard
            let value = try? JSONSerialization.jsonObject(with: data),
            let message = value as? JSONObject
        else {
            return
        }

        if let id = Self.integerID(message["id"]), let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? JSONObject {
                let code = Self.integerID(error["code"]) ?? -1
                let detail = error["message"] as? String ?? "Unknown app-server error"
                continuation.resume(throwing: HarnessError.serverError(code: code, message: detail))
            } else if let result = message["result"] as? JSONObject {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: HarnessError.malformedResponse("missing result"))
            }
            return
        }

        if message["id"] != nil, message["method"] != nil {
            respondUnsupported(to: message)
            return
        }

        guard message["method"] != nil else { return }
        let handler = onNotification
        DispatchQueue.main.async { handler?(message) }
    }

    private func respondUnsupported(to message: JSONObject) {
        guard let input = inputPipe?.fileHandleForWriting, let id = message["id"] else { return }
        let response: JSONObject = [
            "id": id,
            "error": ["code": -32601, "message": "Bobbin does not support this server request"]
        ]
        if let data = try? Self.encodedLine(response) {
            try? input.write(contentsOf: data)
        }
    }

    private func appendErrorOutput(_ text: String) {
        recentErrorOutput += text
        if recentErrorOutput.count > 4_000 {
            recentErrorOutput = String(recentErrorOutput.suffix(4_000))
        }
    }

    private func handleTermination(status: Int32) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        let detail = recentErrorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = HarnessError.appServerStopped(detail.isEmpty ? "exit status \(status)" : detail)
        let continuations = pending.values
        pending.removeAll()
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        for continuation in continuations { continuation.resume(throwing: error) }
        let handler = onTermination
        DispatchQueue.main.async { handler?(error) }
    }

    private static func encodedLine(_ object: JSONObject) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw HarnessError.malformedResponse("request is not valid JSON")
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private static func integerID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    public static func findCodexExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".bun/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
