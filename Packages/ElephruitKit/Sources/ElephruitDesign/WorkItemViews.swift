import ElephruitCore
import SwiftUI

/// The shared chrome of a work item, so a card, a row and a table cell agree about what a bug looks
/// like. Kept in the design system rather than in Features because four views draw these.

/// `ELE-42`, in a form that reads as a handle rather than as prose.
public struct WorkItemReferenceLabel: View {
    public let reference: String

    public init(reference: String) {
        self.reference = reference
    }

    public var body: some View {
        Text(reference)
            .font(Theme.Text.rowSubtitle)
            .monospaced()
            .foregroundStyle(Theme.Colors.tertiaryText)
            .fixedSize()
            .accessibilityLabel("Reference \(reference)")
    }
}

/// The glyph for a kind, tinted by severity when there is one.
public struct WorkItemKindGlyph: View {
    public let kind: ItemKind
    public let severity: BugSeverity?

    public init(kind: ItemKind, severity: BugSeverity? = nil) {
        self.kind = kind
        self.severity = severity
    }

    public var body: some View {
        Image(systemName: kind.symbolName)
            .foregroundStyle(tint)
            .accessibilityLabel(accessibilityText)
    }

    private var tint: Color {
        Theme.Palette.color(named: severity?.colorName, neutral: Theme.Colors.secondaryText)
    }

    private var accessibilityText: String {
        guard let severity else { return kind.displayName }
        return "\(severity.displayName) \(kind.displayName)"
    }
}

/// Says something is waiting on something else.
public struct BlockedMarker: View {
    public init() {}

    public var body: some View {
        Image(systemName: "hand.raised.fill")
            .font(.system(size: 10))
            .foregroundStyle(Theme.Colors.warning)
            .accessibilityLabel("Blocked")
    }
}

/// How long something was expected to take.
public struct EstimateLabel: View {
    public let minutes: Int

    public init(minutes: Int) {
        self.minutes = minutes
    }

    public var body: some View {
        Text(Self.duration(minutes))
            .font(Theme.Text.rowSubtitle)
            .monospacedDigit()
            .foregroundStyle(Theme.Colors.tertiaryText)
            .accessibilityLabel("Estimated \(Self.duration(minutes))")
    }

    /// Public so the table and the sheet format an estimate the same way this row does.
    public static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}
