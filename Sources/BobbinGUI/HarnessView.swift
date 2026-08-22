import AppKit
import SwiftUI
import BobbinCore

private func presentFolderChooser(
    startingAt path: String,
    onChoose: (String) -> Void
) {
    let panel = NSOpenPanel()
    panel.title = "Working folder"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: path)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    onChoose(url.path)
}

/// The authenticated part of the menu-bar popover.
///
/// The list is intentionally the landing view. A thread is opened as a
/// separate, focused conversation so the popover does not keep two dense
/// panes visible at once.
///
/// The popover does not introduce itself: there is no wordmark, badge or
/// standing health light. The thread list starts with the action the user is
/// most likely to take, while the conversation owns its own header.
@MainActor
final class PopoverSessionState: ObservableObject {
    enum Destination: Equatable {
        case threadList
        case conversation(UUID)
        case systemPrompt
    }

    @Published var destination: Destination = .threadList
    @Published var systemPromptDraft = ""
}

struct HarnessView: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject var store: ThreadStore
    @ObservedObject var session: PopoverSessionState

    var body: some View {
        VStack(spacing: 0) {
            switch session.destination {
            case .systemPrompt:
                // A drill-down rather than a sheet. The menu-bar popover closes
                // the moment it stops being the key window, so any modal
                // presented from it takes its own parent down with it.
                SystemPromptView(
                    controller: controller,
                    draft: $session.systemPromptDraft,
                    back: closeSystemPrompt
                )
            case .conversation(let conversationID):
                ConversationView(
                    controller: controller,
                    store: store,
                    threadID: conversationID,
                    back: closeConversation
                )
            case .threadList:
                ThreadListView(
                    controller: controller,
                    store: store,
                    open: openConversation,
                    openSystemPrompt: openSystemPrompt
                )
            }
        }
        .background(.regularMaterial)
    }

    private func openSystemPrompt() {
        session.systemPromptDraft = store.state.defaultSystemPrompt
        withAnimation(.easeOut(duration: 0.16)) {
            session.destination = .systemPrompt
        }
    }

    private func openConversation(_ id: UUID) {
        controller.selectThread(id)
        withAnimation(.easeOut(duration: 0.16)) {
            session.destination = .conversation(id)
        }
    }

    private func closeConversation() {
        withAnimation(.easeOut(duration: 0.16)) {
            session.destination = .threadList
        }
    }

    private func closeSystemPrompt() {
        withAnimation(.easeOut(duration: 0.16)) {
            session.systemPromptDraft = ""
            session.destination = .threadList
        }
    }
}

/// One shared action treatment for both composers, so the landing field and a
/// conversation never drift into looking like different controls.
private struct ComposerActionButton: View {
    let isRunning: Bool
    let isDisabled: Bool
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(foregroundColor)
                .frame(width: 30, height: 30)
                .background(backgroundColor, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(helpText)
        .accessibilityLabel(isRunning ? "Stop generating" : "Send")
    }

    private var foregroundColor: Color {
        isDisabled ? Color.primary.opacity(0.55) : Color(nsColor: .windowBackgroundColor)
    }

    private var backgroundColor: Color {
        if isRunning { return .red }
        return isDisabled ? Color.primary.opacity(0.09) : .primary
    }
}

/// The shared inset surface around both the new-thread and conversation
/// composers. Their contents differ, but their geometry should not.
private struct ComposerSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.leading, 11)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 13)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(Color.primary.opacity(0.09), lineWidth: 1)
            }
    }
}

private struct WorkingDirectoryButton: View {
    let path: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(path)
        .accessibilityLabel("Working folder: \(path)")
    }
}

private struct ThreadListView: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject var store: ThreadStore
    let open: (UUID) -> Void
    let openSystemPrompt: () -> Void

    @State private var showingServerDetail = false
    @State private var draft = ""
    @State private var workingDirectory: String
    @FocusState private var editorFocused: Bool

    init(
        controller: HarnessController,
        store: ThreadStore,
        open: @escaping (UUID) -> Void,
        openSystemPrompt: @escaping () -> Void
    ) {
        self.controller = controller
        self.store = store
        self.open = open
        self.openSystemPrompt = openSystemPrompt
        _workingDirectory = State(initialValue: controller.newThreadWorkingDirectory)
    }

    var body: some View {
        VStack(spacing: 0) {
            newThreadField
            threadHeader

            ServerBanner(
                notice: controller.serverState.notice,
                showingDetail: $showingServerDetail,
                restart: controller.restart
            )

            ScrollView {
                LazyVStack(spacing: 1) {
                    if store.activeThreads.isEmpty, store.savedThreads.isEmpty {
                        EmptyThreadView()
                    } else {
                        ForEach(store.activeThreads) { thread in
                            ThreadRow(
                                thread: thread,
                                isSelected: false,
                                opacity: controller.opacity(for: thread),
                                select: { open(thread.id) },
                                save: { controller.saveThread(thread.id) }
                            )
                        }

                        if !store.savedThreads.isEmpty {
                            SavedSection(
                                threads: store.savedThreads,
                                selectedID: store.state.selectedThreadID,
                                open: open
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.automatic)
        }
        .onAppear {
            // A list visit starts from the user's home in production or from
            // a fixture directory in demo mode. The chosen folder is
            // view-local and is never persisted as a default.
            workingDirectory = controller.newThreadWorkingDirectory
            editorFocused = true
        }
    }

    private var newThreadField: some View {
        ComposerSurface {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("New thread…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .lineLimit(1...3)
                        .focused($editorFocused)
                        .onKeyPress(.return, phases: .down) { keyPress in
                            guard !keyPress.modifiers.contains(.shift) else {
                                return .ignored
                            }
                            submit()
                            return .handled
                        }

                    WorkingDirectoryButton(path: workingDirectory, action: chooseFolder)
                }

                ComposerActionButton(
                    isRunning: false,
                    isDisabled: isSendDisabled,
                    helpText: controller.serverState.isHealthy
                        ? "Send"
                        : "Unavailable until the app-server is ready",
                    action: submit
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var threadHeader: some View {
        HStack(spacing: 5) {
            Spacer(minLength: 3)

            SettingsMenu(
                controller: controller,
                openSystemPrompt: openSystemPrompt
            )
        }
        .padding(.horizontal, 13)
        .frame(height: 24)
    }

    private var isDraftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSendDisabled: Bool {
        isDraftEmpty || controller.serverState != .ready
    }

    private func submit() {
        guard !isDraftEmpty, controller.serverState == .ready else {
            return
        }

        let text = draft
        draft = ""
        guard let id = controller.createThreadAndSend(
            text: text,
            workingDirectory: workingDirectory
        ) else {
            return
        }
        open(id)
    }

    private func chooseFolder() {
        presentFolderChooser(startingAt: workingDirectory) { path in
            workingDirectory = path
            editorFocused = true
        }
    }
}

private struct SettingsMenu: View {
    @ObservedObject var controller: HarnessController
    let openSystemPrompt: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Section("Default model") {
                    ForEach(controller.availableModels) { option in
                        Button {
                            controller.updateDefaultModel(option.id)
                        } label: {
                            settingsChoiceLabel(
                                option.displayName,
                                selected: option.id == controller.store.state.defaultModel
                            )
                        }
                    }
                }

                Section("Default reasoning") {
                    ForEach(
                        controller.reasoningEfforts(for: controller.store.state.defaultModel),
                        id: \.self
                    ) { effort in
                        Button {
                            controller.updateDefaultReasoningEffort(effort)
                        } label: {
                            settingsChoiceLabel(
                                effort,
                                selected: effort == controller.store.state.defaultReasoningEffort
                            )
                        }
                    }
                }

                Divider()
                Button("System prompt…", action: openSystemPrompt)
                // Status lives here, on demand, rather than as a permanent
                // light on the main surface.
                Text("Server: \(controller.serverState.settingsLabel)")
                if !controller.isDemoMode {
                    Button("Restart app-server", action: controller.restart)
                }
                Text("Auth: \(authenticationLabel)")
                Divider()
                Button("Quit Bobbin") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }

    private var authenticationLabel: String {
        if case .authenticated(let mode) = controller.authState { return mode.rawValue }
        return "Not connected"
    }

    @ViewBuilder
    private func settingsChoiceLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

/// The system prompt editor, drilled into from the settings menu.
///
/// It is a page inside the popover rather than a sheet, for the same reason the
/// conversation is: a sheet needs a host window that stays key, and the
/// menu-bar popover dismisses itself as soon as it is not. Changes are saved as
/// they are typed, so Back only controls navigation.
private struct SystemPromptView: View {
    @ObservedObject var controller: HarnessController
    @Binding var draft: String
    let back: () -> Void

    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Back")
                .accessibilityLabel("Back")

                Text("System prompt")
                    .font(.system(size: 12.5, weight: .semibold))

                Spacer(minLength: 3)
            }
            .padding(.horizontal, 7)
            .frame(height: 38)

            Text("Applied to new threads")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .frame(height: 24)

            TextEditor(text: $draft)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(7)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                }
                .padding(.horizontal, 11)
                .padding(.bottom, 11)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            editorFocused = true
        }
        .onChange(of: draft) { _, newValue in
            guard newValue != controller.store.state.defaultSystemPrompt else { return }
            controller.updateSystemPrompt(newValue)
        }
    }
}

/// Renders nothing at all while the app-server is healthy.
///
/// Both the list and the conversation embed one of these, so an actionable
/// state reaches the user wherever they happen to be.
private struct ServerBanner: View {
    let notice: ServerNotice
    @Binding var showingDetail: Bool
    let restart: () -> Void

    var body: some View {
        switch notice {
        case .none:
            EmptyView()
        case .restarting:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.62)
                    .frame(width: 10, height: 10)
                Text("Restarting app-server…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Restarting app-server")
        case .stopped(let detail):
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text("Server stopped")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !detail.isEmpty {
                        Button(showingDetail ? "Hide" : "Details") {
                            withAnimation(.easeOut(duration: 0.12)) {
                                showingDetail.toggle()
                            }
                        }
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.plain)
                    }
                    Button("Restart", action: restart)
                        .font(.system(size: 10, weight: .semibold))
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                if showingDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
        }
    }
}

private struct EmptyThreadView: View {
    var body: some View {
        Text("Type above to start a thread.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 150)
    }
}

private struct SavedSection: View {
    let threads: [HarnessThread]
    let selectedID: UUID?
    let open: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("SAVED")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.top, 9)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            ForEach(threads) { thread in
                ThreadRow(
                    thread: thread,
                    isSelected: selectedID == thread.id,
                    opacity: 1,
                    select: { open(thread.id) },
                    save: {}
                )
            }
        }
        .overlay(alignment: .top) { Divider() }
        .padding(.top, 8)
    }
}

private struct ThreadRow: View {
    let thread: HarnessThread
    let isSelected: Bool
    let opacity: Double
    let select: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            Button(action: select) {
                HStack(spacing: 7) {
                    if thread.status == .running {
                        Circle()
                            .fill(Color.harnessAccent)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("Running")
                    }

                    Text(thread.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    Spacer(minLength: 3)

                    if !thread.isSaved {
                        Text(metadata)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)

            Button(action: save) {
                Image(systemName: thread.isSaved ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(thread.isSaved ? Color.harnessAccent : Color.secondary)
                    .frame(width: 25, height: 25)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(thread.isSaved)
            .help(thread.isSaved ? "Saved" : "Save and keep")
            .accessibilityLabel(thread.isSaved ? "Saved" : "Save thread")
        }
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(opacity)
    }

    private var accessibilityLabel: String {
        if thread.isSaved { return "\(thread.title), saved" }
        return "\(thread.title), \(metadata)"
    }

    private var metadata: String {
        if thread.status == .running { return "Running" }
        let age = max(0, Date().timeIntervalSince(thread.lastConversationAt))
        let remaining = Int(ceil((7 * 24 * 60 * 60 - age) / (24 * 60 * 60)))
        if remaining <= 2 { return "\(max(0, remaining))d left" }
        if age < 60 { return "Just now" }
        if age < 3_600 { return "\(Int(age / 60))m ago" }
        if age < 86_400 { return "\(Int(age / 3_600))h ago" }
        return "\(Int(age / 86_400))d ago"
    }
}

private struct ConversationView: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject var store: ThreadStore
    let threadID: UUID
    let back: () -> Void

    @State private var prompt = ""
    @State private var showingServerDetail = false
    @State private var editingMessageID: UUID?
    @State private var editDraft = ""

    private var thread: HarnessThread? {
        store.state.threads.first { $0.id == threadID }
    }

    var body: some View {
        if let thread {
            VStack(spacing: 0) {
                ConversationHeader(
                    controller: controller,
                    thread: thread,
                    save: { controller.saveThread(thread.id) },
                    back: back,
                    chooseFolder: { chooseFolder(for: thread) },
                    selectModel: { model, effort in
                        controller.updateModel(model, reasoningEffort: effort, for: thread.id)
                    },
                    selectReviewMode: { mode in
                        controller.updateReviewMode(mode, for: thread.id)
                    }
                )

                ServerBanner(
                    notice: controller.serverState.notice,
                    showingDetail: $showingServerDetail,
                    restart: controller.restart
                )

                Divider()
                messageList(thread)
                composer(thread)
            }
        } else {
            Color.clear.onAppear(perform: back)
        }
    }

    private func messageList(_ thread: HarnessThread) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(transcriptBlocks(for: thread)) { block in
                        switch block {
                        case .message(let message):
                            MessageBubble(
                                message: message,
                                isEditing: editingMessageID == message.id,
                                editDraft: $editDraft,
                                showsEditAction: showsEditAction(for: message, in: thread),
                                showsRegenerateAction: showsRegenerateAction(
                                    for: message,
                                    in: thread
                                ),
                                actionsEnabled: rewriteActionsEnabled(for: thread),
                                beginEditing: { beginEditing(message) },
                                cancelEditing: cancelEditing,
                                submitEdit: { submitEdit(message, in: thread) },
                                regenerate: {
                                    controller.regenerateResponse(message.id, in: thread.id)
                                }
                            )
                                .id("message:\(message.id.uuidString)")
                        case .toolCalls(let toolCalls):
                            ToolCallGroup(controller: controller, toolCalls: toolCalls)
                        }
                    }

                    // Quiet assistant-side placeholder while the turn is in
                    // flight. The first assistant delta appends a message, so
                    // this disappears on its own.
                    if isAwaitingAssistant(thread) {
                        PendingReplyIndicator()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.automatic)
            .onChange(of: thread.transcriptEntries) { _, entries in
                guard let last = entries.last else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcriptBlocks(for thread: HarnessThread) -> [TranscriptBlock] {
        thread.transcriptEntries.reduce(into: [TranscriptBlock]()) { blocks, entry in
            switch entry {
            case .message(let message):
                blocks.append(.message(message))
            case .toolCall(let toolCall):
                if case .toolCalls(let existing)? = blocks.last {
                    blocks[blocks.count - 1] = .toolCalls(existing + [toolCall])
                } else {
                    blocks.append(.toolCalls([toolCall]))
                }
            }
        }
    }

    private func composer(_ thread: HarnessThread) -> some View {
        ComposerSurface {
            HStack(alignment: .bottom, spacing: 8) {
                // A vertical-axis TextField gives the placeholder for free, so the
                // prompt and the placeholder share one inset and one baseline. It
                // starts exactly one line tall and grows to `maxComposerLines`
                // before it starts scrolling.
                TextField("Message", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...maxComposerLines)
                    .frame(minHeight: 30, alignment: .center)
                    .disabled(editingMessageID != nil || controller.isRewriting(thread.id))

                ComposerActionButton(
                    isRunning: thread.status == .running,
                    isDisabled: isSendDisabled(thread),
                    helpText: sendHelp(thread),
                    action: sendOrStop
                )
                .keyboardShortcut(
                    editingMessageID == nil
                        ? KeyboardShortcut(.return, modifiers: .command)
                        : nil
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .top) { Divider() }
        .opacity(
            editingMessageID == nil && !controller.isRewriting(thread.id) ? 1 : 0.55
        )
    }

    /// Explains the disabled send button rather than leaving it inert and
    /// unlabelled while the app-server is unavailable.
    private func sendHelp(_ thread: HarnessThread) -> String {
        if thread.status == .running { return "Stop generating" }
        return controller.serverState.isHealthy ? "Send" : "Unavailable until the app-server is ready"
    }

    /// Restrained ceiling for the composer inside a 392x560 popover: past this
    /// the field scrolls instead of eating the conversation.
    private var maxComposerLines: Int { 5 }

    private var isPromptEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isSendDisabled(_ thread: HarnessThread) -> Bool {
        thread.status != .running
            && (
                editingMessageID != nil
                    || controller.isRewriting(thread.id)
                    || isPromptEmpty
                    || controller.serverState != .ready
            )
    }

    private func isAwaitingAssistant(_ thread: HarnessThread) -> Bool {
        thread.status == .running && thread.messages.last?.role == .user
    }

    private func sendOrStop() {
        guard let thread else { return }
        if thread.status == .running {
            controller.stopThread(thread.id)
        } else {
            guard editingMessageID == nil else { return }
            let outgoing = prompt
            prompt = ""
            controller.send(outgoing, in: thread.id)
        }
    }

    private func showsEditAction(for message: ChatMessage, in thread: HarnessThread) -> Bool {
        message.role == .user
            && thread.status != .running
            && editingMessageID == nil
            && !controller.isRewriting(thread.id)
            && !controller.isDemoMode
    }

    private func showsRegenerateAction(
        for message: ChatMessage,
        in thread: HarnessThread
    ) -> Bool {
        guard
            message.role == .assistant,
            thread.status != .running,
            editingMessageID == nil,
            !controller.isRewriting(thread.id),
            !controller.isDemoMode,
            let index = thread.messages.firstIndex(where: { $0.id == message.id }),
            thread.messages[..<index].contains(where: { $0.role == .user })
        else { return false }

        // A turn can emit more than one assistant item around tool calls. Keep
        // one Regenerate action on the final assistant item for that turn.
        for following in thread.messages.dropFirst(index + 1) {
            if following.role == .user { break }
            if following.role == .assistant { return false }
        }
        return true
    }

    private func rewriteActionsEnabled(for thread: HarnessThread) -> Bool {
        thread.status != .running
            && !controller.isRewriting(thread.id)
            && controller.serverState == .ready
            && controller.authState.isAuthenticated
            && controller.modelVerified
    }

    private func beginEditing(_ message: ChatMessage) {
        guard message.role == .user else { return }
        editDraft = message.text
        editingMessageID = message.id
    }

    private func cancelEditing() {
        editingMessageID = nil
        editDraft = ""
    }

    private func submitEdit(_ message: ChatMessage, in thread: HarnessThread) {
        let replacement = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty, rewriteActionsEnabled(for: thread) else { return }
        if controller.editMessage(message.id, replacement: replacement, in: thread.id) {
            cancelEditing()
        }
    }

    private func chooseFolder(for thread: HarnessThread) {
        presentFolderChooser(startingAt: thread.workingDirectory) { path in
            controller.updateWorkingDirectory(path, for: thread.id)
        }
    }
}

private struct ConversationHeader: View {
    @ObservedObject var controller: HarnessController
    let thread: HarnessThread
    let save: () -> Void
    let back: () -> Void
    let chooseFolder: () -> Void
    let selectModel: (String, String) -> Void
    let selectReviewMode: (HarnessReviewMode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Back to threads")
                .accessibilityLabel("Back to threads")

                Text(thread.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 3)

                Button(action: save) {
                    Image(systemName: thread.isSaved ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(thread.isSaved ? Color.harnessAccent : Color.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(thread.isSaved)
                .help(thread.isSaved ? "Saved" : "Save and keep")
                .accessibilityLabel(thread.isSaved ? "Saved" : "Save thread")
            }
            .padding(.horizontal, 7)
            .frame(height: 38)

            HStack(spacing: 7) {
                WorkingDirectoryButton(path: thread.workingDirectory, action: chooseFolder)

                Spacer(minLength: 3)
                ThreadOptionsRow(
                    controller: controller,
                    thread: thread,
                    selectModel: selectModel,
                    selectReviewMode: selectReviewMode
                )
            }
            .padding(.horizontal, 13)
            .frame(height: 24)
        }
    }
}

/// The per-thread settings that sit above the composer: review mode, model and
/// reasoning effort. They read as one quiet line of metadata, but each item is
/// its own menu, so nothing carries a disclosure indicator.
private struct ThreadOptionsRow: View {
    @ObservedObject var controller: HarnessController
    let thread: HarnessThread
    let selectModel: (String, String) -> Void
    let selectReviewMode: (HarnessReviewMode) -> Void

    var body: some View {
        HStack(spacing: 3) {
            Menu {
                ForEach(HarnessReviewMode.allCases) { mode in
                    Button {
                        selectReviewMode(mode)
                    } label: {
                        choiceLabel(mode.displayName, selected: mode == thread.reviewMode)
                    }
                }
            } label: {
                optionLabel(thread.reviewMode.displayName)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Approvals: \(thread.reviewMode.displayName) — \(thread.reviewMode.summary)")
            .accessibilityLabel(
                "Approval mode \(thread.reviewMode.displayName), \(thread.reviewMode.summary). Click to change"
            )

            separator

            Menu {
                ForEach(controller.availableModels) { option in
                    Button {
                        let effort = controller.resolvedReasoningEffort(
                            for: option.id,
                            keeping: thread.reasoningEffort
                        )
                        selectModel(option.id, effort)
                    } label: {
                        choiceLabel(
                            HarnessController.modelNickname(option.id),
                            selected: option.id == thread.model
                        )
                    }
                }
            } label: {
                optionLabel(HarnessController.modelNickname(thread.model))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Model: \(thread.model)")
            .accessibilityLabel("Model \(thread.model). Click to change")

            separator

            Menu {
                ForEach(controller.reasoningEfforts(for: thread.model), id: \.self) { effort in
                    Button {
                        selectModel(thread.model, effort)
                    } label: {
                        choiceLabel(effort, selected: effort == thread.reasoningEffort)
                    }
                }
            } label: {
                optionLabel(thread.reasoningEffort)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reasoning: \(thread.reasoningEffort)")
            .accessibilityLabel("Reasoning \(thread.reasoningEffort). Click to change")
        }
        .padding(.horizontal, 5)
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.tertiary)
    }

    private func optionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(height: 24)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func choiceLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

private enum TranscriptBlock: Identifiable {
    case message(ChatMessage)
    case toolCalls([ToolCall])

    var id: String {
        switch self {
        case .message(let message): "message:\(message.id.uuidString)"
        case .toolCalls(let toolCalls):
            "toolCalls:\(toolCalls.first?.id.uuidString ?? UUID().uuidString)"
        }
    }
}

private struct ToolCallGroup: View {
    @ObservedObject var controller: HarnessController
    let toolCalls: [ToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(toolCalls) { toolCall in
                ToolCallRow(
                    toolCall: toolCall,
                    output: controller.toolOutput(for: toolCall.itemID)
                )
                .id("toolCall:\(toolCall.id.uuidString)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolCallRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    let toolCall: ToolCall
    let output: String?

    private var hasOutput: Bool { output?.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hasOutput {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isExpanded.toggle()
                    }
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
            } else {
                rowContent
            }

            if isExpanded, let output {
                ScrollView(.vertical) {
                    Text(verbatim: output)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 104, alignment: .top)
                .padding(.leading, 18)
                .padding(.vertical, 5)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 5)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { pulsing = true }
    }

    @State private var isExpanded = false

    private var rowContent: some View {
        HStack(spacing: 5) {
            Image(systemName: glyphName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 13)
                .opacity(glyphOpacity)
                .scaleEffect(glyphScale)
                .animation(glyphAnimation, value: pulsing)
                .accessibilityHidden(true)

            Text(verbatim: toolCall.label)
                .font(
                    .system(
                        size: toolCall.kind == .command ? 10.5 : 11,
                        design: toolCall.kind == .command ? .monospaced : .default
                    )
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(toolCall.status == .running ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let trailingValue {
                Text(trailingValue)
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(
                        toolCall.status == .failed
                            ? Color.red
                            : toolCall.status == .running ? Color.primary : Color.secondary
                    )
            }
        }
        .frame(minHeight: 15, alignment: .center)
        .contentShape(Rectangle())
    }

    private var glyphName: String {
        switch toolCall.kind {
        case .command: "terminal"
        case .fileChange: "pencil"
        case .mcpTool: "hammer"
        case .webSearch: "magnifyingglass"
        case .other: "gearshape"
        }
    }

    private var glyphOpacity: Double {
        guard toolCall.status == .running else { return 0.72 }
        return reduceMotion ? 1 : (pulsing ? 1 : 0.45)
    }

    private var glyphScale: CGFloat {
        guard toolCall.status == .running, !reduceMotion else { return 1 }
        return pulsing ? 1 : 0.88
    }

    private var glyphAnimation: Animation? {
        guard toolCall.status == .running, !reduceMotion else { return nil }
        return .easeInOut(duration: 0.65)
            .repeatForever(autoreverses: true)
    }

    private var trailingValue: String? {
        if toolCall.status == .failed {
            if let exitCode = toolCall.exitCode { return "exit \(exitCode)" }
            return "failed"
        }
        guard let durationMs = toolCall.durationMs else { return nil }
        return String(
            format: "%.1fs",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(durationMs) / 1_000
        )
    }

    private var accessibilityLabel: String {
        if isExpanded { return "\(toolCall.label), hide output" }
        return "\(toolCall.label), show output"
    }
}

private struct PendingReplyIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.tertiary)
                    .frame(width: 4, height: 4)
                    .opacity(dimmed ? 0.3 : 1)
                    .scaleEffect(dimmed ? 0.72 : 1)
                    .animation(animation(delayedBy: index), value: pulsing)
            }
        }
        .frame(height: 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waiting for a reply")
        .onAppear { pulsing = true }
    }

    /// With Reduce Motion the dots simply sit at rest, which reads as a static
    /// ellipsis; otherwise they ride the repeating pulse.
    private var dimmed: Bool { !reduceMotion && !pulsing }

    private func animation(delayedBy index: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: 0.55)
            .repeatForever(autoreverses: true)
            .delay(Double(index) * 0.16)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let isEditing: Bool
    @Binding var editDraft: String
    let showsEditAction: Bool
    let showsRegenerateAction: Bool
    let actionsEnabled: Bool
    let beginEditing: () -> Void
    let cancelEditing: () -> Void
    let submitEdit: () -> Void
    let regenerate: () -> Void

    @State private var isHovering = false
    @FocusState private var editFieldFocused: Bool
    @FocusState private var rewriteButtonFocused: Bool

    @ViewBuilder
    var body: some View {
        VStack(
            alignment: message.role == .user ? .trailing : .leading,
            spacing: 2
        ) {
            if isEditing {
                inlineEditor
            } else {
                messageContent

                if showsEditAction {
                    rewriteButton(
                        systemImage: "pencil",
                        help: actionsEnabled
                            ? "Edit this message and replace everything after it"
                            : "Unavailable until the app-server is ready",
                        accessibilityLabel: "Edit message",
                        accessibilityIdentifier: "message.edit.\(message.id.uuidString)",
                        action: beginEditing
                    )
                } else if showsRegenerateAction {
                    rewriteButton(
                        systemImage: "arrow.clockwise",
                        help: actionsEnabled
                            ? "Regenerate this response and replace everything after it"
                            : "Unavailable until the app-server is ready",
                        accessibilityLabel: "Regenerate response",
                        accessibilityIdentifier: "message.regenerate.\(message.id.uuidString)",
                        action: regenerate
                    )
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
        .onHover { isHovering = $0 }
    }

    private var messageText: some View {
        Text(message.text)
            .font(.system(size: 12.5))
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.role == .user {
            messageText
                .foregroundStyle(Color.primary)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(message.text)
                .accessibilityIdentifier("message.user.\(message.id.uuidString)")
        } else {
            messageText
                .foregroundStyle(message.role == .system ? Color.red : Color.primary)
                .accessibilityLabel(message.text)
                .accessibilityIdentifier("message.\(message.role.rawValue).\(message.id.uuidString)")
        }
    }

    private var inlineEditor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Edit message", text: $editDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...5)
                .focused($editFieldFocused)
                .onKeyPress(.escape, phases: .down) { _ in
                    cancelEditing()
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { keyPress in
                    guard keyPress.modifiers.contains(.command), !isEditSubmitDisabled else {
                        return .ignored
                    }
                    submitEdit()
                    return .handled
                }
                .accessibilityIdentifier("message.edit-field.\(message.id.uuidString)")

            HStack(spacing: 7) {
                Button("Cancel", action: cancelEditing)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel editing")
                    .accessibilityIdentifier("message.edit-cancel.\(message.id.uuidString)")

                Button(action: submitEdit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 27, height: 27)
                        .background(
                            isEditSubmitDisabled ? Color.primary.opacity(0.15) : .primary,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(isEditSubmitDisabled)
                .help("Send edited message")
                .accessibilityLabel("Send edited message")
                .accessibilityIdentifier("message.edit-submit.\(message.id.uuidString)")
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.13), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onAppear { editFieldFocused = true }
    }

    private var isEditSubmitDisabled: Bool {
        !actionsEnabled || editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func rewriteButton(
        systemImage: String,
        help: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!actionsEnabled)
        .focused($rewriteButtonFocused)
        .opacity(actionsEnabled ? (isHovering || rewriteButtonFocused ? 0.9 : 0.48) : 0.25)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
