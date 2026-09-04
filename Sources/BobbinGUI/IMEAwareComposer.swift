import AppKit
import SwiftUI
import BobbinCore

/// A small AppKit-backed composer. SwiftUI's `onKeyPress` runs after the text
/// input system has had a chance to process Return, which means an IME can
/// both commit marked text and trigger a send handler. Keeping Return handling
/// on the NSTextView lets us inspect `NSTextInputClient.hasMarkedText` at the
/// point where AppKit dispatches the key event.
struct IMEAwareComposer: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let fontSize: CGFloat
    let maxLines: Int
    let isEnabled: Bool
    let onSubmit: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            IMEAwareComposerTextView(
                text: $text,
                isFocused: $isFocused,
                fontSize: fontSize,
                maxLines: maxLines,
                isEnabled: isEnabled,
                onSubmit: onSubmit
            )

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct IMEAwareComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let fontSize: CGFloat
    let maxLines: Int
    let isEnabled: Bool
    let onSubmit: () -> Void

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView view: IMEAwareComposerContainer,
        context: Context
    ) -> CGSize? {
        // HStack can propose its full available height to an NSViewRepresentable.
        // The composer height is content-driven instead: it grows from one line
        // to maxLines and lets its document view scroll beyond that ceiling.
        let width = max(proposal.width ?? view.bounds.width, 1)
        return CGSize(
            width: proposal.width ?? width,
            height: view.textView.fittingHeight(for: width)
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> IMEAwareComposerContainer {
        let view = IMEAwareComposerContainer(frame: .zero)
        view.textView.delegate = context.coordinator
        configure(view.textView)
        return view
    }

    func updateNSView(_ view: IMEAwareComposerContainer, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        configure(view.textView)

        if view.textView.string != text {
            view.textView.string = text
            view.invalidateIntrinsicContentSize()
            view.needsLayout = true
        }

        if isFocused {
            context.coordinator.requestFocusIfNeeded(for: view.textView)
        } else {
            context.coordinator.resetFocusRequest()
        }

        if !isEnabled, view.window?.firstResponder === view.textView {
            view.window?.makeFirstResponder(nil)
        }
    }

    private func configure(_ view: IMEAwareTextView) {
        view.font = .systemFont(ofSize: fontSize)
        view.maxLines = maxLines
        view.isComposerEnabled = isEnabled
        view.onSubmit = onSubmit
        view.isEditable = isEnabled
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.textColor = .labelColor
        view.insertionPointColor = .controlAccentColor
        view.textContainerInset = NSSize(width: 0, height: 7)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        private var didRequestFocus = false

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? IMEAwareTextView else { return }
            if text.wrappedValue != view.string {
                text.wrappedValue = view.string
            }
            view.owner?.invalidateIntrinsicContentSize()
            view.owner?.needsLayout = true
            view.owner?.layoutSubtreeIfNeeded()
            view.scrollRangeToVisible(view.selectedRange())
        }

        func requestFocusIfNeeded(for view: IMEAwareTextView) {
            guard !didRequestFocus, let window = view.window else { return }
            didRequestFocus = window.makeFirstResponder(view)
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard notification.object is IMEAwareTextView else { return }
            didRequestFocus = true
            isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            guard notification.object is IMEAwareTextView else { return }
            didRequestFocus = false
            isFocused.wrappedValue = false
        }

        func resetFocusRequest() {
            didRequestFocus = false
        }
    }
}

/// Hosts the text view in a scroll view while exposing only a
/// `maxLines`-line height to SwiftUI. The document view is allowed to grow past
/// that height, so AppKit can keep the caret and current selection visible.
private final class IMEAwareComposerContainer: NSView {
    let textView: IMEAwareTextView
    private let scrollView: NSScrollView

    override init(frame frameRect: NSRect) {
        textView = IMEAwareTextView(frame: .zero)
        scrollView = NSScrollView(frame: .zero)
        super.init(frame: frameRect)

        textView.owner = self
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: textView.fittingHeight(for: max(bounds.width, 1))
        )
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds

        let viewport = scrollView.contentView.bounds.size
        let width = max(viewport.width, bounds.width, 1)
        let contentHeight = textView.contentHeight(for: width)
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(contentHeight, viewport.height)
        )
        textView.needsLayout = true
    }
}

private final class IMEAwareTextView: NSTextView {
    weak var owner: IMEAwareComposerContainer?
    var maxLines = 5
    var isComposerEnabled = true
    var onSubmit: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    func contentHeight(for width: CGFloat) -> CGFloat {
        guard let textContainer, let layoutManager else { return 32 }

        textContainer.containerSize = NSSize(
            width: max(width, 1),
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let lineHeight = layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: 12))
        let verticalInsets = textContainerInset.height * 2
        return max(lineHeight, usedHeight) + verticalInsets
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager else { return 32 }

        let contentHeight = contentHeight(for: width)
        let lineHeight = layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: 12))
        let verticalInsets = textContainerInset.height * 2
        let maximumHeight = lineHeight * CGFloat(maxLines) + verticalInsets
        return min(maximumHeight, max(32, ceil(contentHeight)))
    }

    override func keyDown(with event: NSEvent) {
        guard isReturnKey(event), isComposerEnabled else {
            super.keyDown(with: event)
            return
        }

        let action = ComposerReturnPolicy.action(
            isShiftPressed: event.modifierFlags.contains(.shift),
            // This is the NSTextInputClient state for the active AppKit text
            // input session. Do not infer composition from the Swift String.
            hasMarkedText: hasMarkedText()
        )

        switch action {
        case .commitMarkedText, .insertNewline:
            // AppKit/IME owns this Return. In particular, forwarding a marked
            // Return commits the composition without invoking onSubmit.
            super.keyDown(with: event)
        case .send:
            onSubmit?()
        }
    }

    private func isReturnKey(_ event: NSEvent) -> Bool {
        // 36 is Return and 76 is the numeric keypad Enter key. Both are
        // represented by SwiftUI's `.return` key value.
        event.keyCode == 36 || event.keyCode == 76
    }
}
