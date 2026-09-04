import Foundation

/// The action a composer should take for a Return key event.
///
/// The GUI supplies AppKit's `NSTextInputClient.hasMarkedText` value to this
/// policy. Keeping the branching independent of AppKit makes the important
/// IME contract testable without synthesising an input source in a UI test.
public enum ComposerReturnAction: Equatable, Sendable {
    case commitMarkedText
    case insertNewline
    case send
}

public enum ComposerReturnPolicy {
    /// Shift+Return always inserts a newline. A plain Return while an IME has
    /// marked text is reserved for committing that text; only a plain Return
    /// after composition has finished submits the prompt.
    public static func action(
        isShiftPressed: Bool,
        hasMarkedText: Bool
    ) -> ComposerReturnAction {
        if isShiftPressed { return .insertNewline }
        if hasMarkedText { return .commitMarkedText }
        return .send
    }
}
