import AppKit

extension Theme {
    /// The design system's colours, as AppKit sees them.
    ///
    /// The note editor draws with AppKit — fonts, paragraph decorations, list markers — and AppKit
    /// wants `NSColor`. These are the same semantic choices as ``Theme/Colors``, made once here
    /// rather than once per call site, so the house rule that no view names a literal colour holds
    /// on both sides of the `NSViewRepresentable` boundary. Every one of these adapts to light
    /// mode, dark mode, Increase Contrast and the user's accent on its own.
    public enum AppKitColors {
        public static let primaryText = NSColor.labelColor
        public static let secondaryText = NSColor.secondaryLabelColor
        public static let tertiaryText = NSColor.tertiaryLabelColor
        public static let placeholderText = NSColor.placeholderTextColor

        /// The fill behind a code block and behind inline code.
        public static let subtleFill = NSColor.quaternarySystemFill

        public static let separator = NSColor.separatorColor

        /// A link that points at something. The accent, as ``Theme/Colors/link`` is.
        public static let link = NSColor.controlAccentColor

        /// A wiki link whose target does not exist yet — a first-class state, not a broken link.
        public static let unresolvedLink = NSColor.systemOrange

        public static let selection = NSColor.controlAccentColor
    }
}

// The palette's AppKit accessors live in `Tokens.swift`, beside the palette itself — the source
// hygiene scan rightly treats any other file that spells out colour names as a second palette.
