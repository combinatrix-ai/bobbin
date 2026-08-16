import AppKit
import SwiftUI
import TinyHarnessCore

/// The authenticated part of the menu-bar popover.
///
/// The list is intentionally the landing view. A thread is opened as a
/// separate, focused conversation so the popover does not keep two dense
/// panes visible at once.
struct HarnessView: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject var store: ThreadStore

    @State private var showingConversation = false
    @State private var conversationID: UUID?

    var body: some View {
        Group {
            if showingConversation, let conversationID {
                ConversationView(
                    controller: controller,
                    store: store,
                    threadID: conversationID,
                    back: closeConversation
                )
            } else {
                ThreadListView(
                    controller: controller,
                    store: store,
                    open: openConversation,
                    create: createThread
                )
            }
        }
        .onAppear {
            // The menu-bar popover always opens on the lightweight index.
            // The selected ID remains persisted by ThreadStore for the next
            // conversation and for app-server resume.
            showingConversation = false
            conversationID = nil
        }
    }

    private func openConversation(_ id: UUID) {
        controller.selectThread(id)
        conversationID = id
        withAnimation(.easeOut(duration: 0.16)) {
            showingConversation = true
        }
    }

    private func createThread() {
        controller.createThread()
        // createThread selects the new item in the store. Defer one run-loop
        // so the published state has reached SwiftUI before reading it.
        DispatchQueue.main.async {
            guard let id = store.selectedThread?.id else { return }
            conversationID = id
            withAnimation(.easeOut(duration: 0.16)) {
                showingConversation = true
            }
        }
    }

    private func closeConversation() {
        withAnimation(.easeOut(duration: 0.16)) {
            showingConversation = false
        }
    }
}

private struct ThreadListView: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject var store: ThreadStore
    let open: (UUID) -> Void
    let create: () -> Void

    @State private var showingServerDetail = false

    var body: some View {
        VStack(spacing: 0) {
            ListHeader(controller: controller, create: create)

            if case .stopped(let detail) = controller.serverState {
                ServerBanner(
                    detail: detail,
                    showingDetail: $showingServerDetail,
                    restart: controller.restart
                )
            }

            ScrollView {
                LazyVStack(spacing: 1) {
                    if store.activeThreads.isEmpty, store.savedThreads.isEmpty {
                        EmptyThreadView(create: create)
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
        .background(.regularMaterial)
    }
}

private struct ListHeader: View {
    @ObservedObject var controller: HarnessController
    let create: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("ti")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(-0.6)
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .frame(width: 21, height: 19)
                .background(.primary, in: RoundedRectangle(cornerRadius: 5))

            Text("Tiny Harness")
                .font(.system(size: 12.5, weight: .semibold))

            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .accessibilityLabel(controller.serverState.label)

            Spacer(minLength: 4)

            Button(action: create) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 27, height: 27)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("新しいスレッド")
            .accessibilityLabel("新しいスレッド")

            Menu {
                Section("デフォルトモデル") {
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

                Section("デフォルト推論") {
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
                Text("認証: \(authenticationLabel)")
                Button("app-serverを再起動", action: controller.restart)
                Divider()
                Button("Tiny Harnessを終了") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 27, height: 27)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("設定")
            .accessibilityLabel("設定")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var statusColor: Color {
        switch controller.serverState {
        case .starting: .secondary
        case .ready: .green
        case .stopped: .red
        }
    }

    private var authenticationLabel: String {
        if case .authenticated(let mode) = controller.authState { return mode.rawValue }
        return "未接続"
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

private struct ServerBanner: View {
    let detail: String
    @Binding var showingDetail: Bool
    let restart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text("サーバー停止")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !detail.isEmpty {
                    Button(showingDetail ? "閉じる" : "詳細") {
                        withAnimation(.easeOut(duration: 0.12)) {
                            showingDetail.toggle()
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.plain)
                }
                Button("再起動", action: restart)
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
        .padding(.top, 6)
    }
}

private struct EmptyThreadView: View {
    let create: () -> Void

    var body: some View {
        Button(action: create) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("新しいスレッド")
        .accessibilityLabel("新しいスレッド")
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
                Text("保存済み")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
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
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("実行中")
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
                    .foregroundStyle(thread.isSaved ? Color.green : Color.secondary)
                    .frame(width: 25, height: 25)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(thread.isSaved)
            .help(thread.isSaved ? "保存済み" : "保存して残す")
            .accessibilityLabel(thread.isSaved ? "保存済み" : "スレッドを保存")
        }
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(opacity)
    }

    private var accessibilityLabel: String {
        if thread.isSaved { return "\(thread.title)、保存済み" }
        return "\(thread.title)、\(metadata)"
    }

    private var metadata: String {
        if thread.status == .running { return "実行中" }
        let age = max(0, Date().timeIntervalSince(thread.lastConversationAt))
        let remaining = Int(ceil((7 * 24 * 60 * 60 - age) / (24 * 60 * 60)))
        if remaining <= 2 { return "残り\(max(0, remaining))日" }
        if age < 60 { return "たった今" }
        if age < 3_600 { return "\(Int(age / 60))分前" }
        if age < 86_400 { return "\(Int(age / 3_600))時間前" }
        return "\(Int(age / 86_400))日前"
    }
}

private struct ConversationView: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject var store: ThreadStore
    let threadID: UUID
    let back: () -> Void

    @State private var prompt = ""
    @State private var showingServerDetail = false

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
                    }
                )

                if case .stopped(let detail) = controller.serverState {
                    ServerBanner(
                        detail: detail,
                        showingDetail: $showingServerDetail,
                        restart: controller.restart
                    )
                }

                Divider()
                messageList(thread)
                composer(thread)
            }
            .background(.regularMaterial)
        } else {
            Color.clear.onAppear(perform: back)
        }
    }

    private func messageList(_ thread: HarnessThread) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(thread.messages) { message in
                        MessageBubble(message: message).id(message.id)
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
            .onChange(of: thread.messages) { _, messages in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func composer(_ thread: HarnessThread) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            // A vertical-axis TextField gives the placeholder for free, so the
            // prompt and the placeholder share one inset and one baseline. It
            // starts exactly one line tall and grows to `maxComposerLines`
            // before it starts scrolling.
            TextField("メッセージ", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...maxComposerLines)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                }

            Button(action: sendOrStop) {
                Image(systemName: thread.status == .running ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 30, height: 30)
                    .background(thread.status == .running ? Color.red : Color.primary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(thread.status == .running ? false : isPromptEmpty || controller.serverState != .ready)
            .opacity(thread.status == .running || !isPromptEmpty ? 1 : 0.3)
            .help(thread.status == .running ? "生成を停止" : "送信")
            .accessibilityLabel(thread.status == .running ? "生成を停止" : "送信")
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .top) { Divider() }
    }

    /// Restrained ceiling for the composer inside a 392x560 popover: past this
    /// the field scrolls instead of eating the conversation.
    private var maxComposerLines: Int { 5 }

    private var isPromptEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isAwaitingAssistant(_ thread: HarnessThread) -> Bool {
        thread.status == .running && thread.messages.last?.role == .user
    }

    private func sendOrStop() {
        guard let thread else { return }
        if thread.status == .running {
            controller.stopThread(thread.id)
        } else {
            let outgoing = prompt
            prompt = ""
            controller.send(outgoing, in: thread.id)
        }
    }

    private func chooseFolder(for thread: HarnessThread) {
        let panel = NSOpenPanel()
        panel.title = "作業フォルダ"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: thread.workingDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.updateWorkingDirectory(url.path, for: thread.id)
    }
}

private struct ConversationHeader: View {
    @ObservedObject var controller: HarnessController
    let thread: HarnessThread
    let save: () -> Void
    let back: () -> Void
    let chooseFolder: () -> Void
    let selectModel: (String, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("スレッド一覧に戻る")
                .accessibilityLabel("スレッド一覧に戻る")

                Text(thread.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 3)

                Button(action: save) {
                    Image(systemName: thread.isSaved ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(thread.isSaved ? Color.green : Color.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(thread.isSaved)
                .help(thread.isSaved ? "保存済み" : "保存して残す")
                .accessibilityLabel(thread.isSaved ? "保存済み" : "スレッドを保存")
            }
            .padding(.horizontal, 7)
            .frame(height: 40)

            HStack(spacing: 7) {
                Button(action: chooseFolder) {
                    Label(folderName, systemImage: "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(thread.workingDirectory)
                .accessibilityLabel("作業フォルダ: \(thread.workingDirectory)")

                Spacer(minLength: 3)
                ModelPicker(controller: controller, thread: thread, select: selectModel)
            }
            .padding(.horizontal, 13)
            .frame(height: 24)
        }
    }

    private var folderName: String {
        URL(fileURLWithPath: thread.workingDirectory).lastPathComponent
    }
}

private struct ModelPicker: View {
    @ObservedObject var controller: HarnessController
    let thread: HarnessThread
    let select: (String, String) -> Void

    var body: some View {
        HStack(spacing: 3) {
            Menu {
                ForEach(controller.availableModels) { option in
                    Button {
                        let effort = option.supportedReasoningEfforts.contains(thread.reasoningEffort)
                            ? thread.reasoningEffort
                            : option.supportedReasoningEfforts.first ?? HarnessController.defaultEffort
                        select(option.id, effort)
                    } label: {
                        choiceLabel(
                            HarnessController.modelNickname(option.id),
                            selected: option.id == thread.model
                        )
                    }
                }
            } label: {
                Text(HarnessController.modelNickname(thread.model))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("モデル: \(thread.model)")
            .accessibilityLabel("モデル \(thread.model)。クリックして変更")

            Text("·")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)

            Menu {
                ForEach(controller.reasoningEfforts(for: thread.model), id: \.self) { effort in
                    Button {
                        select(thread.model, effort)
                    } label: {
                        choiceLabel(effort, selected: effort == thread.reasoningEffort)
                    }
                }
            } label: {
                Text(thread.reasoningEffort)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("reasoning: \(thread.reasoningEffort)")
            .accessibilityLabel("推論 \(thread.reasoningEffort)。クリックして変更")
        }
        .padding(.horizontal, 5)
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

private struct PendingReplyIndicator: View {
    var body: some View {
        Text("…")
            .font(.system(size: 12.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("応答を待っています")
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        Text(message.text)
            .font(.system(size: 12.5))
            .textSelection(.enabled)
            .foregroundStyle(message.role == .system ? Color.red : Color.primary)
            .padding(message.role == .user ? 8 : 0)
            .background(message.role == .user ? Color(nsColor: .controlBackgroundColor) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
            .accessibilityLabel(message.text)
    }
}
