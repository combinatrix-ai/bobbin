import AppKit
import SwiftUI
import TinyHarnessCore

struct HarnessView: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject var store: ThreadStore

    var body: some View {
        HStack(spacing: 0) {
            ThreadSidebar(controller: controller, store: store)
                .frame(width: 154)
            Divider()
            if let thread = store.selectedThread {
                ConversationView(controller: controller, store: store, threadID: thread.id)
            } else {
                ContentUnavailableView("No thread", systemImage: "bubble.left")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ThreadSidebar: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject var store: ThreadStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Threads")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    controller.createThread()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("New thread")
            }
            .padding(.leading, 8)
            .padding(.trailing, 5)
            .frame(height: 38)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(store.activeThreads) { thread in
                        ThreadRow(
                            thread: thread,
                            isSelected: store.state.selectedThreadID == thread.id,
                            opacity: controller.opacity(for: thread),
                            select: { controller.selectThread(thread.id) },
                            save: { controller.saveThread(thread.id) }
                        )
                    }
                }
                .padding(.horizontal, 7)
            }

            VStack(spacing: 0) {
                Divider().padding(.bottom, 7)
                Text("Saved")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)

                if store.savedThreads.isEmpty {
                    Text("保存した結果はここに残ります")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(store.savedThreads) { thread in
                                ThreadRow(
                                    thread: thread,
                                    isSelected: store.state.selectedThreadID == thread.id,
                                    opacity: 1,
                                    select: { controller.selectThread(thread.id) },
                                    save: {}
                                )
                            }
                        }
                        .padding(.horizontal, 7)
                    }
                    .frame(maxHeight: 130)
                }

                Divider().padding(.top, 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text("7 day cleanup").font(.system(size: 9.5, weight: .semibold))
                    Text("最終会話から7日で自動削除")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }
}

private struct ThreadRow: View {
    let thread: HarnessThread
    let isSelected: Bool
    let opacity: Double
    let select: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(metadata)
                        .font(.system(size: 9.5))
                        .foregroundStyle(thread.status == .running ? Color.green : .secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 7)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: save) {
                Image(systemName: thread.isSaved ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(thread.isSaved ? Color.green : .secondary)
                    .frame(width: 23, height: 23)
            }
            .buttonStyle(.plain)
            .disabled(thread.isSaved)
            .help(thread.isSaved ? "Saved" : "Save thread")
        }
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.14) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .opacity(opacity)
    }

    private var metadata: String {
        if thread.isSaved { return "Saved" }
        if thread.status == .running { return "Running · now" }
        return relativeDate(thread.lastConversationAt)
    }

    private func relativeDate(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) hours ago" }
        return "\(Int(seconds / 86_400)) days ago"
    }
}

private struct ConversationView: View {
    @ObservedObject var controller: HarnessController
    @ObservedObject var store: ThreadStore
    let threadID: UUID

    @State private var prompt = ""

    private var thread: HarnessThread? {
        store.state.threads.first { $0.id == threadID }
    }

    var body: some View {
        if let thread {
            VStack(spacing: 0) {
                conversationHeader(thread)
                Divider()
                messageList(thread)
                Divider()
                composer(thread)
            }
        }
    }

    private func conversationHeader(_ thread: HarnessThread) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Button {
                    chooseFolder(for: thread)
                } label: {
                    Label(URL(fileURLWithPath: thread.workingDirectory).lastPathComponent, systemImage: "folder")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(thread.workingDirectory)
            }
            Spacer()
            Button(thread.isSaved ? "保存済み" : "結果を保存") {
                controller.saveThread(thread.id)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(thread.isSaved)

            Text("luna · xhigh")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 25)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 13)
        .frame(height: 52)
    }

    private func messageList(_ thread: HarnessThread) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if thread.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("New thread").font(.system(size: 12, weight: .semibold))
                            Text("このスレッドはTiny Harness専用の履歴領域で動きます。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(thread.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                }
                .padding(15)
            }
            .onChange(of: thread.messages) { _, messages in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func composer(_ thread: HarnessThread) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("追加の指示を送る")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 10)
                        .padding(.leading, 9)
                }
                TextEditor(text: $prompt)
                    .font(.system(size: 11.5))
                    .scrollContentBackground(.hidden)
                    .padding(4)
            }
            .frame(height: 64)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(alignment: .bottomTrailing) {
                Button {
                    let outgoing = prompt
                    prompt = ""
                    controller.send(outgoing, in: thread.id)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 29, height: 29)
                        .background(.primary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thread.status == .running)
                .opacity(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
                .padding(7)
                .keyboardShortcut(.return, modifiers: .command)
            }

            HStack {
                Text("未保存は最終会話から7日で削除")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                if thread.status == .running {
                    Button {
                        controller.stopThread(thread.id)
                    } label: {
                        Label("Stop run", systemImage: "stop.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 10)
    }

    private func chooseFolder(for thread: HarnessThread) {
        let panel = NSOpenPanel()
        panel.title = "Choose working folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: thread.workingDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.updateWorkingDirectory(url.path, for: thread.id)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(message.text)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .padding(message.role == .user ? 9 : 0)
                .background(message.role == .user ? Color(nsColor: .controlBackgroundColor) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .foregroundStyle(message.role == .system ? Color.red : Color.primary)
    }

    private var label: String {
        switch message.role {
        case .user: "You"
        case .assistant: "Luna"
        case .system: "Tiny Harness"
        }
    }
}
