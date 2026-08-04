import SwiftUI

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// The system colours the tokens are built from, named once per platform.
///
/// `Theme.Colors` is written against *meanings* — "tertiary text", "the content background" —
/// and each platform names those meanings differently: AppKit says `tertiaryLabelColor` and
/// `textBackgroundColor`, UIKit says `tertiaryLabel` and `systemBackground`. This is the one
/// file that knows both vocabularies, so the token definitions themselves stay a single
/// platform-free statement of intent.
///
/// On macOS every value resolves to exactly the `NSColor` the tokens used before this file
/// existed; the mapping is a rename, not a redesign. On iOS each value is the UIKit colour
/// that carries the same semantics — including the two places the platforms genuinely
/// disagree about what a window looks like:
///
/// - ``windowBackground`` is `windowBackgroundColor` on macOS and `systemGroupedBackground`
///   on iOS, because both are "the surface behind the content surfaces".
/// - ``contentBackground`` is `textBackgroundColor` on macOS and `systemBackground` on iOS,
///   because both are "the surface a list or an editor sits on".
enum SystemColors {
    #if canImport(AppKit)
        static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)
        static let placeholderText = Color(nsColor: .placeholderTextColor)
        static let windowBackground = Color(nsColor: .windowBackgroundColor)
        static let contentBackground = Color(nsColor: .textBackgroundColor)
        static let quaternaryFill = Color(nsColor: .quaternarySystemFill)
        static let separator = Color(nsColor: .separatorColor)

        /// What the system paints on top of its own prominent, accent-filled controls.
        ///
        /// AppKit has a token that tracks the accent, the appearance, and Increase Contrast.
        /// UIKit has no equivalent — iOS draws white on filled controls in every appearance —
        /// so white *is* the faithful mapping there, not an approximation of one.
        static let onAccent = Color(nsColor: .alternateSelectedControlTextColor)

        static let red = Color(nsColor: .systemRed)
        static let orange = Color(nsColor: .systemOrange)
        static let yellow = Color(nsColor: .systemYellow)
        static let green = Color(nsColor: .systemGreen)
        static let mint = Color(nsColor: .systemMint)
        static let teal = Color(nsColor: .systemTeal)
        static let cyan = Color(nsColor: .systemCyan)
        static let blue = Color(nsColor: .systemBlue)
        static let indigo = Color(nsColor: .systemIndigo)
        static let purple = Color(nsColor: .systemPurple)
        static let pink = Color(nsColor: .systemPink)
        static let brown = Color(nsColor: .systemBrown)
        static let gray = Color(nsColor: .systemGray)
    #elseif canImport(UIKit)
        static let tertiaryLabel = Color(uiColor: .tertiaryLabel)
        static let placeholderText = Color(uiColor: .placeholderText)
        static let windowBackground = Color(uiColor: .systemGroupedBackground)
        static let contentBackground = Color(uiColor: .systemBackground)
        static let quaternaryFill = Color(uiColor: .quaternarySystemFill)
        static let separator = Color(uiColor: .separator)

        static let onAccent = Color.white

        static let red = Color(uiColor: .systemRed)
        static let orange = Color(uiColor: .systemOrange)
        static let yellow = Color(uiColor: .systemYellow)
        static let green = Color(uiColor: .systemGreen)
        static let mint = Color(uiColor: .systemMint)
        static let teal = Color(uiColor: .systemTeal)
        static let cyan = Color(uiColor: .systemCyan)
        static let blue = Color(uiColor: .systemBlue)
        static let indigo = Color(uiColor: .systemIndigo)
        static let purple = Color(uiColor: .systemPurple)
        static let pink = Color(uiColor: .systemPink)
        static let brown = Color(uiColor: .systemBrown)
        static let gray = Color(uiColor: .systemGray)
    #endif
}
