import AppKit
import SwiftUI

extension Color {
    /// The one accent in the app, borrowed from the mark's own core.
    ///
    /// It carries a single meaning: this thread is doing work, or the user
    /// chose to keep it. It is deliberately never used for "everything is
    /// fine" — a healthy app-server shows nothing at all.
    static let harnessAccent = Color(
        nsColor: NSColor(name: NSColor.Name("harnessAccent")) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(srgbRed: 0.722, green: 0.827, blue: 0.337, alpha: 1)
                : NSColor(srgbRed: 0.525, green: 0.643, blue: 0.118, alpha: 1)
        }
    )
}
