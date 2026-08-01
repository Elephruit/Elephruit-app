import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// Who today involves.
///
/// ### Why this is not a contact list
/// Because a contact list answers "who do I know", and nobody opens a day planner to ask that. These
/// people are here because the day put them here — they are in a meeting, they are waiting on you,
/// it is their birthday — and every card says which. Somebody with no reason to appear does not
/// appear, and somebody with three reasons appears once with three.
struct TodayPeopleGrid: View {
    let people: [DayPerson]
    let plan: DayPlan
    let model: TodayModel
    let actions: TodayActions

    /// How many cards before the rest fold away.
    ///
    /// A busy Tuesday can involve twenty people, and twenty cards is a second page below the day
    /// they belong to. The ones kept are the ones the roster already ranked highest — somebody you
    /// are about to sit down with outranks somebody you have not emailed in six weeks.
    private static let visibleLimit = 6

    @State private var isShowingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ElephruitDesign.FlowLayout(spacing: Theme.Spacing.small, lineSpacing: Theme.Spacing.small) {
                ForEach(visiblePeople) { person in
                    TodayPersonCard(person: person, plan: plan, model: model, actions: actions)
                }
            }

            if people.count > Self.visibleLimit {
                Button {
                    withAnimation(Theme.Motion.standard) { isShowingAll.toggle() }
                } label: {
                    Text(isShowingAll ? "Show fewer" : "\(people.count - Self.visibleLimit) more")
                        .font(Theme.Text.metadata)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.link)
            }
        }
    }

    private var visiblePeople: [DayPerson] {
        isShowingAll ? people : Array(people.prefix(Self.visibleLimit))
    }
}

/// One person, and why they are on today's page.
///
/// ### What a card carries and what it does not
/// A name, why they are here, who they are, when you last spoke, and at most a couple of stated
/// facts. What it does not carry is everything else the library knows: a briefing surface is read in
/// the seconds before a conversation and is the most likely screen in the app to be visible to
/// somebody else in the room, so a *summary* only ever shows what its subject would say out loud.
/// Anything marked sensitive or private, and health and private reflections regardless of how they
/// were marked, stay on the person's own page — one click away, where somebody went looking for them.
struct TodayPersonCard: View {
    @Environment(\.services) private var services

    let person: DayPerson
    let plan: DayPlan
    let model: TodayModel
    let actions: TodayActions

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            header
            reasons
            footer
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 260, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Colors.subtleFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.Colors.separator.opacity(isHovering || isFocused ? 1 : 0.4))
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture { open() }
        .focusable(person.isKnown)
        .focused($isFocused)
        .onKeyPress(.return) {
            open()
            return .handled
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(AccessibilityID.Today.person(person.key))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            PersonAvatar(name: person.name, colorName: person.colorName, size: 34)

            VStack(alignment: .leading, spacing: 0) {
                Text(person.name)
                    .font(Theme.Text.rowTitleEmphasised)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .lineLimit(1)

                if let role = person.roleLine {
                    Text(role)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if person.celebration != nil {
                Image(systemName: "birthday.cake.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.familyAccent)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Why they are here

    /// Every reason, consolidated. Two lines at most, because a card that scrolls is a card nobody
    /// reads.
    private var reasons: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            ForEach(Array(person.reasons.prefix(2).enumerated()), id: \.offset) { _, reason in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.tight) {
                    Image(systemName: reason.symbolName)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .accessibilityHidden(true)

                    Text(reason.sentence(calendar: calendar))
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }
            }

            if person.reasons.count > 2 {
                Text("+\(person.reasons.count - 2) more")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
    }

    // MARK: Context and controls

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            if let quickFact = person.quickFacts.first {
                Text(quickFact)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .lineLimit(2)
            }

            HStack(spacing: Theme.Spacing.small) {
                Text(lastContactText)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Spacer(minLength: 0)

                if isHovering || isFocused, let item = model.person(person.personID) {
                    quickControls(item)
                }
            }
        }
    }

    private var lastContactText: String {
        guard let clock = services?.dateProvider else { return "" }
        guard let last = person.lastContact else {
            // "Never" would be wrong for somebody you talk to daily and have never written down.
            return person.isKnown ? "No contact recorded" : "Not in your people"
        }
        return "Last \(last.kindDescription) \(last.relativeDescription(using: clock))"
    }

    @ViewBuilder
    private func quickControls(_ item: Item) -> some View {
        let contacts = actions.contactActions(for: item)

        HStack(spacing: Theme.Spacing.tight) {
            // Whichever channel their own record actually supports, in the order the People module
            // already ranks them. A Call button on somebody with no number is a button that fails.
            if let primary = contacts.first(where: \.isRunnable) {
                Button { actions.contact(primary, person: item) } label: {
                    Image(systemName: primary.channel.symbolName)
                }
                .help(primary.sentence)
                .accessibilityLabel(primary.sentence)
            }

            Button { actions.select(item.id) } label: {
                Image(systemName: "person.crop.circle")
            }
            .help("Open \(person.name)")
            .accessibilityLabel("Open \(person.name)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.Colors.secondaryText)
        .transition(.opacity)
    }

    @ViewBuilder
    private var menu: some View {
        if let item = model.person(person.personID) {
            Button("Open Profile", systemImage: "person.crop.circle") { actions.select(item.id) }
            Button("Open in People", systemImage: "person.2") { actions.openInModule(item) }

            let contacts = actions.contactActions(for: item).filter(\.isRunnable)
            if !contacts.isEmpty {
                Divider()
                ForEach(contacts, id: \.channel) { preview in
                    Button(preview.channel.verbPhrase.capitalized, systemImage: preview.channel.symbolName) {
                        actions.contact(preview, person: item)
                    }
                }
            }

            Divider()

            Button("Log an Interaction", systemImage: "bubble.left.and.text.bubble.right") {
                actions.logInteraction(with: item, summary: "Spoke with \(person.name)")
            }
            Button("Add a Follow-up", systemImage: "arrow.turn.up.right") {
                actions.createFollowUp(titled: "Follow up with \(person.name)", about: item, on: plan.date)
            }
        } else {
            // On an invitation, not in the library. Saying so is more useful than a menu of
            // controls that cannot run, and linking them by hand is the calendar's own job — where
            // the choice between two people with the same name can actually be made.
            Text("\(person.name) is on the invitation but not in your people")
            Button("Link in Calendar", systemImage: "link") {
                if let event = meetingEvent { actions.openInCalendar(event) }
            }
        }
    }

    private var meetingEvent: DayEvent? {
        for reason in person.reasons {
            if case .meeting(let id, _, _, _) = reason {
                return plan.events.first { $0.id == id }
            }
        }
        return nil
    }

    private func open() {
        guard let id = person.personID else { return }
        actions.select(id)
    }

    private var calendar: Calendar {
        (services?.dateProvider ?? SystemDateProvider()).calendar
    }

    private var accessibilityLabel: String {
        var parts = [person.name]
        if let role = person.roleLine { parts.append(role) }
        parts.append(contentsOf: person.reasons.map { $0.sentence(calendar: calendar) })
        if !lastContactText.isEmpty { parts.append(lastContactText) }
        if let fact = person.quickFacts.first { parts.append(fact) }
        return parts.joined(separator: ", ")
    }
}
