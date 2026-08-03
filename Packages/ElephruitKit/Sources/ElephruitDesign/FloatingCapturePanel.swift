import SwiftUI

/// The semantic design language for the small, global capture windows.
///
/// This is the SwiftUI equivalent of a focused CSS component layer. The base palette and type
/// scale still live in ``Theme``; this layer says what those primitives *mean* in Quick Jot, Quick
/// Log, and future panels of the same kind. A panel should ask for a prompt or input role, not
/// independently decide that `.title2` happens to look right today.
extension Theme {
    public enum FloatingCapturePanel {
        public static let outerPadding = Spacing.section
        public static let sectionSpacing = Spacing.large
        public static let controlSpacing = Spacing.small

        public static let cornerRadius = Radius.large

        public static let promptFont: Font = .system(
            .body, design: .default, weight: .regular
        )
        public static let primaryInputFont: Font = .system(
            .title3, design: .default, weight: .regular
        )
        public static let recordTitleFont: Font = .system(
            .body, design: .default, weight: .semibold
        )
        public static let supportingFont = Text.rowSubtitle
        public static let metadataFont = Text.metadata
        public static let statusFont = Text.keyHint

        public static let background = Colors.windowBackground
        public static let groupedBackground = Colors.subtleFill
        public static let primaryText = Colors.primaryText
        public static let secondaryText = Colors.secondaryText
        public static let tertiaryText = Colors.tertiaryText
    }
}

/// A decision title and its explanation, with one shared hierarchy.
public struct FloatingCapturePanelPrompt: View {
    private let title: String
    private let message: String?

    public init(_ title: String, message: String? = nil) {
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(title)
                .font(Theme.FloatingCapturePanel.promptFont)
                .foregroundStyle(Theme.FloatingCapturePanel.primaryText)

            if let message {
                Text(message)
                    .font(Theme.FloatingCapturePanel.supportingFont)
                    .foregroundStyle(Theme.FloatingCapturePanel.secondaryText)
            }
        }
    }
}
