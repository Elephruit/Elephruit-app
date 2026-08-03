import SwiftUI

/// The semantic design language for the small, global capture windows.
///
/// This is the SwiftUI equivalent of a focused CSS component layer. The base palette and type
/// scale still live in ``Theme``; this layer says what those primitives *mean* in Quick Jot, Quick
/// Log, and future panels of the same kind. A panel should ask for a prompt font or a field surface,
/// not independently decide that `.title2` and a six-point corner happen to look right today.
extension Theme {
    public enum FloatingCapturePanel {
        public static let outerPadding = Spacing.section
        public static let sectionSpacing = Spacing.large
        public static let controlSpacing = Spacing.small
        public static let fieldPadding = Spacing.medium

        public static let cornerRadius = Radius.large

        public static let headerFont: Font = .system(
            .headline, design: .default, weight: .semibold
        )
        public static let promptFont: Font = .system(
            .title3, design: .default, weight: .semibold
        )
        public static let primaryInputFont: Font = .system(
            .title3, design: .default, weight: .regular
        )
        public static let recordTitleFont: Font = .system(
            .body, design: .default, weight: .semibold
        )
        public static let supportingFont = Text.rowSubtitle
        public static let metadataFont = Text.metadata
        public static let sectionLabelFont = Text.sectionHeader
        public static let statusFont = Text.keyHint

        public static let background = Colors.windowBackground
        public static let fieldBackground = Colors.contentBackground
        public static let groupedBackground = Colors.subtleFill
        public static let border = Colors.separator
        public static let primaryText = Colors.primaryText
        public static let secondaryText = Colors.secondaryText
        public static let tertiaryText = Colors.tertiaryText
    }
}

/// The one-line identity shared by every global capture panel.
public struct FloatingCapturePanelHeader<Trailing: View>: View {
    private let title: String
    private let symbolName: String
    private let trailing: Trailing

    public init(
        _ title: String,
        systemImage symbolName: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.symbolName = symbolName
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Label(title, systemImage: symbolName)
                .font(Theme.FloatingCapturePanel.headerFont)
                .foregroundStyle(Theme.FloatingCapturePanel.primaryText)

            Spacer(minLength: Theme.Spacing.small)

            trailing
        }
    }
}

extension FloatingCapturePanelHeader where Trailing == EmptyView {
    public init(_ title: String, systemImage symbolName: String) {
        self.init(title, systemImage: symbolName) { EmptyView() }
    }
}

/// The small uppercase question immediately above an editable capture field.
public struct FloatingCapturePanelSectionLabel: View {
    private let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title.uppercased())
            .font(Theme.FloatingCapturePanel.sectionLabelFont)
            .tracking(Theme.Text.Tracking.caps)
            .foregroundStyle(Theme.FloatingCapturePanel.secondaryText)
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

/// The standard inset, fill, border, and radius around primary panel input.
public struct FloatingCapturePanelField<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.FloatingCapturePanel.fieldPadding)
            .background(
                RoundedRectangle(
                    cornerRadius: Theme.FloatingCapturePanel.cornerRadius,
                    style: .continuous
                )
                .fill(Theme.FloatingCapturePanel.fieldBackground)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: Theme.FloatingCapturePanel.cornerRadius,
                    style: .continuous
                )
                .strokeBorder(Theme.FloatingCapturePanel.border)
            )
    }
}
