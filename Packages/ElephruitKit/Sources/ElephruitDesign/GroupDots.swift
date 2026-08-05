import ElephruitCore
import SwiftUI

/// The groups somebody is in, as a row of coloured dots.
///
/// ### Why dots rather than a tint on the row
/// Because a person can be in several groups, and every design that colours the *person* has to pick
/// one of them to be the real one. Tinting the avatar, ringing it, striping the row — each looks
/// better than this with one group and lies with two, and the lie is the bad kind: it is invisible.
/// Somebody in Family, Work and Cycling would read as being in whichever one happened to sort first,
/// and nothing on screen would say otherwise.
///
/// Dots are the smallest mark that can be plural. Three of them say *three groups* without saying
/// which matters most, because nothing here knows.
///
/// ### Why they are not labelled
/// A row is sixty points tall and already carries a name and an employer; three text chips would
/// take the width the name needs and turn every row into a paragraph. The colour is learnable
/// because the Groups screen teaches it — the same colour, the same order, one tap away — and the
/// names are on the row for VoiceOver regardless, which is the reader that cannot use colour at all.
///
/// ### Why a cap
/// Somebody in nine groups would otherwise push the name out of the row. Past the cap the overflow
/// is counted rather than drawn, because "+4" is honest about there being more and a row of
/// identical dots running off the edge is not.
public struct GroupDots: View {
    private let groups: [PersonListGroupBadge]
    private let limit: Int

    /// Four points, which is as small as a filled circle can be and stay a circle on a 2× screen.
    private static let diameter: CGFloat = 6

    public init(groups: [PersonListGroupBadge], limit: Int = 4) {
        self.groups = groups
        self.limit = max(1, limit)
    }

    public var body: some View {
        if !groups.isEmpty {
            HStack(spacing: Theme.Spacing.hairline) {
                ForEach(groups.prefix(limit)) { group in
                    Circle()
                        .fill(Theme.Palette.color(named: group.colorName, neutral: Theme.Colors.tertiaryText))
                        .frame(width: Self.diameter, height: Self.diameter)
                }

                if groups.count > limit {
                    Text("+\(groups.count - limit)")
                        .font(Theme.Text.keyHint)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .monospacedDigit()
                }
            }
            // Said by the row's own combined label instead — see `MobileRecordRow`. A dot announced
            // on its own is "circle", which is worse than silence.
            .accessibilityHidden(true)
        }
    }

    /// How the groups read aloud, for the row that contains them to fold into its label.
    ///
    /// Every group, not just the drawn ones: the cap exists because the row is narrow, and a screen
    /// reader is not.
    public static func accessibilityText(for groups: [PersonListGroupBadge]) -> String? {
        guard !groups.isEmpty else { return nil }
        return "In \(groups.map(\.name).formatted(.list(type: .and)))"
    }
}

/// A group's colour and symbol together, at the size a list of groups uses.
///
/// The same tile the rest of the app gives a collection, tinted by the group's own colour — so a
/// group is recognisable by colour before its name has been read, which is the whole reason the
/// colour exists.
public struct GroupTile: View {
    private let symbolName: String
    private let colorName: String?
    private let size: IconTile.Size

    public init(symbolName: String, colorName: String?, size: IconTile.Size = .large) {
        self.symbolName = symbolName
        self.colorName = colorName
        self.size = size
    }

    public var body: some View {
        IconTile(
            systemImage: symbolName,
            tint: Theme.Palette.color(named: colorName, neutral: Theme.Colors.secondaryText),
            size: size
        )
    }
}

#Preview("Group dots") {
    let badge = { (name: String, color: String?) in
        PersonListGroupBadge(id: UUID(), name: name, colorName: color)
    }

    return VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        GroupDots(groups: [badge("Family", "blue")])
        GroupDots(groups: [badge("Family", "blue"), badge("Work", "purple")])
        GroupDots(groups: [
            badge("Family", "blue"), badge("Work", "purple"), badge("Cycling", "green"),
            badge("Book club", "orange"), badge("Neighbors", "pink"), badge("Choir", "teal"),
        ])
        GroupDots(groups: [badge("Uncolored", nil)])

        HStack(spacing: Theme.Spacing.medium) {
            GroupTile(symbolName: "figure.2.and.child.holdinghands", colorName: "blue")
            GroupTile(symbolName: "square.grid.2x2", colorName: "purple")
            GroupTile(symbolName: "person.2.badge.gearshape", colorName: nil)
        }
    }
    .padding(Theme.Spacing.section)
}
