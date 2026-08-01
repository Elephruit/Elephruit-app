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

// The heading above a group of details on a person's card used to be a tinted capsule here —
// `ContactAffinityChip`. It is a plain section heading now, and it lives in `PersonContactViews`
// beside the grid it is a row of, because that is the only place it can be aligned with the labels
// underneath it. See the note on `ContactAffinityHeading` for why a pill was the wrong shape: it was
// the only one in a pane that has none, it read at the weight of the values it was introducing, and
// sitting outside the grid it lined up with nothing.
