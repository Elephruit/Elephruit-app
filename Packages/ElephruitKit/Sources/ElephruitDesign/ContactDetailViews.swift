import ElephruitCore
import SwiftUI

/// How a labelled contact detail is drawn, wherever one appears.
///
/// In the design system rather than in the People feature because a row in the middle column and a
/// card in the detail pane must agree about what "Work" looks like — and because the rule that the
/// colour is never the *only* signal is easier to keep in one file than in two.
extension ContactAffinity {
    /// The colour that marks this side of somebody's life.
    ///
    /// Always accompanied by the word and the symbol wherever it is drawn — see
    /// ``Theme/Colors/workDetail``. ``ContactAffinity/unspecified`` deliberately has no colour of its
    /// own: inventing one would make "mobile" look like a third category rather than an absence.
    public var color: Color {
        switch self {
        case .personal: Theme.Colors.personalDetail
        case .work: Theme.Colors.workDetail
        case .unspecified: Theme.Colors.secondaryText
        }
    }
}

/// One contact detail as it reads in a list row — `✉ Work · caroline@example.com`.
///
/// The label is coloured and the value is not, so a column of these can be scanned for "which of
/// these is her work address" without reading any of them.
public struct ContactDetailLabel: View {
    private let detail: ContactDetail

    public init(_ detail: ContactDetail) {
        self.detail = detail
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: detail.kind.symbolName)
                .font(Theme.Text.metadata)
                .rowTint(detail.affinity.color)
                .accessibilityHidden(true)

            Text(detail.displayLabel)
                .font(Theme.Text.chip)
                .rowTint(detail.affinity.color)

            Text(detail.displayValue)
                .font(Theme.Text.metadata)
                .rowForeground(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(detail.displayLabel) \(detail.kind.displayName.lowercased()), \(detail.displayValue)")
    }
}

/// The heading above a group of details on a person's card — `⌂ Personal`.
public struct ContactAffinityChip: View {
    private let affinity: ContactAffinity

    public init(_ affinity: ContactAffinity) {
        self.affinity = affinity
    }

    public var body: some View {
        Label(affinity.displayName, systemImage: affinity.symbolName)
            .font(Theme.Text.chip)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(affinity.color)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(affinity.color.opacity(0.14))
            )
            .accessibilityLabel("\(affinity.displayName) details")
    }
}
