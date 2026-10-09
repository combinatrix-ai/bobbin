import Foundation

public final class CodexAppServerClient: @unchecked Sendable {
    public typealias JSONObject = [String: Any]
    public typealias NotificationHandler = (JSONObject) -> Void
    public typealias TerminationHandler = (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.tinyharness.app-server")
    private let stateQueueKey = DispatchSpecificKey<Bool>()
    private let codexHome: URL
    private let executableURL: URL

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var recentErrorOutput = ""
    private var nextID = 1
    private var pending: [RPCID: CheckedContinuation<JSONObject, Error>] = [:]
    private var generation = UUID()
    private var inbound: [RPCID: ServerRequestToken] = [:]
    public typealias ApprovalHandler = (ServerRequestToken, ComputerUseApproval) -> Void
    public var onComputerUseApproval: ApprovalHandler?

    public var onNotification: NotificationHandler?
    public var onTermination: TerminationHandler?

    public init(codexHome: URL, executableURL: URL? = nil) throws {
        self.codexHome = codexHome
        guard let executableURL = executableURL ?? Self.findCodexExecutable() else {
            throw HarnessError.codexNotFound
        }
        self.executableURL = executableURL
        stateQueue.setSpecific(key: stateQueueKey, value: true)
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        stateQueue.sync { process?.isRunning == true }
    }

    public func start() async throws {
        if isRunning { return }

        let epoch = UUID()
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
            self?.stateQueue.async {
                guard let self, self.generation == epoch else { return }
                self.consumeOutput(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.stateQueue.async {
                guard let self, self.generation == epoch else { return }
                self.appendErrorOutput(text)
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.stateQueue.async {
                guard let self, self.generation == epoch else { return }
                self.handleTermination(status: process.terminationStatus, epoch: epoch)
            }
        }

        try stateQueue.sync {
            guard self.process == nil else { throw HarnessError.malformedResponse("app-server already started") }
            self.generation = epoch
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            self.outputBuffer.removeAll(keepingCapacity: true)
            self.recentErrorOutput = ""
            do { try process.run() } catch {
                settleAndClear(error)
                throw error
            }
        }

        _ = try await request(
            method: "initialize",
            params: [
                "capabilities": ["experimentalApi": true, "mcpServerOpenaiFormElicitation": true],
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
        if DispatchQueue.getSpecific(key: stateQueueKey) == true {
            stopOnQueue()
        } else {
            stateQueue.sync { stopOnQueue() }
        }
    }

    private func stopOnQueue() {
        generation = UUID()
        if process?.isRunning == true { process?.terminate() }
        settleAndClear(HarnessError.appServerStopped("Stopped"))
    }

    private func settleAndClear(_ error: Error) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll()
        inbound.removeAll()
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    public func respond(to token: ServerRequestToken, decision: ComputerUseDecision) {
        stateQueue.async {
            guard token.generation == self.generation,
                  self.inbound[token.id] == token else { return }
            self.inbound.removeValue(forKey: token.id)
            self.writeResponse(id: token.id, result: decision.result)
        }
    }

    public func request(method: String, params: JSONObject? = nil) async throws -> JSONObject {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
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
                    self.pending[.integer(Int64(id))] = continuation
                    try input.write(contentsOf: data)
                    self.stateQueue.asyncAfter(deadline: .now() + 360) { [weak self] in
                        self?.pending.removeValue(forKey: .integer(Int64(id)))?.resume(
                            throwing: HarnessError.malformedResponse("Timed out waiting for " + method)
                        )
                    }
                } catch {
                    self.pending.removeValue(forKey: .integer(Int64(id)))
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

        if let method = message["method"] as? String {
            if message["id"] != nil {
                guard let id = RPCID(message["id"]) else { return }
                guard inbound[id] == nil else { return }
                let params = message["params"] as? JSONObject ?? [:]
                if let approval = ComputerUseApproval(method: method, params: params), let handler = onComputerUseApproval {
                    let token = ServerRequestToken(generation: generation, id: id, nonce: UUID())
                    inbound[id] = token
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.stateQueue.sync(execute: { self.inbound[id] == token }) else { return }
                        handler(token, approval)
                    }
                } else if method == "mcpServer/elicitation/request" {
                    writeResponse(id: id, result: ComputerUseDecision.decline.result)
                } else {
                    writeResponse(id: id, error: ["code": -32601, "message": "Bobbin does not support this server request"])
                }
                return
            }
            if method == "serverRequest/resolved", let params = message["params"] as? JSONObject,
               let id = RPCID(params["requestId"]) { inbound.removeValue(forKey: id) }
            let epoch = generation
            let handler = onNotification
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stateQueue.sync(execute: { self.generation == epoch }) else { return }
                handler?(message)
            }
            return
        }
        guard let id = RPCID(message["id"]), let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? JSONObject {
            let code = (error["code"] as? NSNumber)?.intValue ?? -1
            continuation.resume(throwing: HarnessError.serverError(code: code, message: error["message"] as? String ?? "Unknown app-server error"))
        } else if let result = message["result"] as? JSONObject {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: HarnessError.malformedResponse("missing result"))
        }
    }

    private func writeResponse(id: RPCID, result: JSONObject? = nil, error: JSONObject? = nil) {
        guard let input = inputPipe?.fileHandleForWriting else { return }
        var response: JSONObject = ["id": id.json]
        if let result { response["result"] = result }
        if let error { response["error"] = error }
        if let data = try? Self.encodedLine(response) { try? input.write(contentsOf: data) }
    }

    private func appendErrorOutput(_ text: String) {
        recentErrorOutput += text
        if recentErrorOutput.count > 4_000 {
            recentErrorOutput = String(recentErrorOutput.suffix(4_000))
        }
    }

    private func handleTermination(status: Int32, epoch: UUID) {
        let detail = recentErrorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = HarnessError.appServerStopped(detail.isEmpty ? "exit status \(status)" : detail)
        settleAndClear(error)
        let handler = onTermination
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stateQueue.sync(execute: { self.generation == epoch }) else { return }
            handler?(error)
        }
    }

    private static func encodedLine(_ object: JSONObject) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw HarnessError.malformedResponse("request is not valid JSON")
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
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
