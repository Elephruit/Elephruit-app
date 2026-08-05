import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import SwiftUI

/// Gathering the day's people under the things that put them there.
///
/// Pure, and separate from the view, so "who is grouped with whom" is a rule with a test rather than
/// a shape a layout happens to produce.
enum TodayPeopleGrouping {
    /// Why a group exists.
    enum Kind {
        /// One event, several people. The event is the row; the people are its content.
        case gathering(title: String, startAt: Date, isAllDay: Bool)
        /// No shared occasion — a birthday, a chase, a task about somebody.
        case alone
    }

    struct Group: Identifiable {
        var id: String
        var kind: Kind
        var people: [DayPerson]
    }

    /// The day's people, gathered.
    ///
    /// Grouped on the **primary** reason only. Somebody in two meetings belongs to the earlier one
    /// — that is what `DayPerson`'s own ordering already decided — and putting them in both would
    /// make a page of five people look like a page of nine.
    static func groups(in plan: DayPlan) -> [Group] {
        var order: [String] = []
        var byID: [String: Group] = [:]

        for person in plan.people {
            let id: String
            let kind: Kind

            if case .meeting(let eventID, let title, let startAt, let isAllDay) = person.primaryReason {
                id = "event:\(eventID)"
                kind = .gathering(title: title, startAt: startAt, isAllDay: isAllDay)
            } else {
                // Kept apart rather than pooled into one "everybody else" row: their reasons have
                // nothing in common, and a row headed by nothing is not a group.
                id = "person:\(person.key)"
                kind = .alone
            }

            if byID[id] == nil {
                byID[id] = Group(id: id, kind: kind, people: [person])
                order.append(id)
            } else {
                byID[id]?.people.append(person)
            }
        }

        return order.compactMap { byID[$0] }
    }
}

/// A meeting, drawn as the people in it.
///
/// Closed, it is one line: the time, the faces, the title. Opened, each person gets the room their
/// detail needs. The faces are the summary — a glance at four initials answers "who am I with at
/// four" without reading a word.
struct TodayGatheringRow: View {
    let title: String
    let startAt: Date
    let isAllDay: Bool
    let people: [DayPerson]
    let isExpanded: Bool
    let toggle: () -> Void
    let open: (UUID) -> Void

    /// How many faces are drawn before the rest become a count.
    ///
    /// Four fits the narrowest phone beside a title without either crowding the other. Past that a
    /// stack of overlapping circles stops being recognisable faces and becomes a texture, which is
    /// the moment a number says more than another disc.
    private static let visibleFaces = 4

    var body: some View {
        VStack(spacing: 0) {
            TimelineRow(
                badge: Timeline.Badge(symbolName: "person.2", tint: Theme.Colors.selection),
                showsDivider: !isExpanded
            ) {
                Text(isAllDay ? "All day" : startAt.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Text.metadata)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.secondaryText)
            } content: {
                Button(action: toggle) {
                    HStack(spacing: Theme.Spacing.small) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                            faces
                            Text(title)
                                .font(Theme.Text.rowSubtitle)
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.forward")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            // Turned rather than swapped, so it is visibly the same control in both
                            // states and the change reads as one thing moving.
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(summary)
            .accessibilityHint(isExpanded ? "Closes the people in this meeting" : "Shows who is in this meeting")
            .accessibilityIdentifier("today.gathering")

            if isExpanded {
                ForEach(people) { person in
                    TodayPersonRow(person: person, showsReason: false, isNested: true)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let id = person.personID { open(id) }
                        }
                        .accessibilityIdentifier("today.gathering.person")
                }
            }
        }
    }

    /// Overlapping discs, oldest-first, with the overflow said as a number.
    private var faces: some View {
        HStack(spacing: -Theme.Spacing.small) {
            ForEach(people.prefix(Self.visibleFaces)) { person in
                PersonAvatar(name: person.name, colorName: person.colorName)
                    // A ring in the page's own colour, so overlapping discs read as separate faces
                    // rather than as one shape with bites out of it.
                    .overlay(Circle().strokeBorder(Theme.Colors.contentBackground, lineWidth: 2))
            }

            if people.count > Self.visibleFaces {
                Text("+\(people.count - Self.visibleFaces)")
                    .font(Theme.Text.denseLabel.weight(.semibold))
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: PersonAvatar.size, height: PersonAvatar.size)
                    .background(Theme.Colors.subtleFill, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.Colors.contentBackground, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }

    private var summary: String {
        let when = isAllDay ? "All day" : startAt.formatted(date: .omitted, time: .shortened)
        let names = ListPhrase.joined(people.map(\.name))
        return "\(when), \(title), with \(names)"
    }
}

/// One person as a disc: their initials, in their own colour.
struct PersonAvatar: View {
    static let size: CGFloat = 32

    let name: String
    let colorName: String?

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.Palette.color(named: colorName).opacity(0.2))
            Text(initials)
                .font(Theme.Text.denseLabel.weight(.semibold))
                .foregroundStyle(Theme.Palette.color(named: colorName))
        }
        .frame(width: Self.size, height: Self.size)
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        let letters = [parts.first, parts.count > 1 ? parts.last : nil]
            .compactMap { $0?.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
