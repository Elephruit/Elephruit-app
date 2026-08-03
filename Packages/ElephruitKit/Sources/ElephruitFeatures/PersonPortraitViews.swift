import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The structured half of a person's page.
///
/// Cards appear only when they hold something, so an empty person is a name and an invitation rather
/// than fourteen blank fields. The free-text note sits among them rather than above them, because a
/// paragraph about somebody is one more thing that is true about them and not a different category of
/// information.
struct PersonPortraitSection: View {
    @Environment(\.services) private var services
    @Environment(\.prefersMonospacedEditor) private var prefersMonospaced

    let person: Item
    let portrait: PersonPortrait?
    @Binding var bodyText: String

    let onAddFact: (QuickFactSeed?) -> Void
    let onConfirm: (PortraitValue) -> Void
    let onCorrect: (PortraitValue) -> Void
    let onDelete: (PortraitValue) -> Void
    let onOpenSource: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack {
                // No explanatory subtitle. NOTES and CONTACT beside it have none, and a heading that
                // needs a gloss is a heading that is not doing its job — "Quick Facts" is already the
                // useful things to remember.
                SectionHeader("Quick Facts", count: factCount)
                Spacer()
                Button {
                    onAddFact(nil)
                } label: {
                    Label("Add quick fact", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .font(Theme.Text.rowSubtitle)
                .accessibilityIdentifier(AccessibilityID.People.addFact)
            }

            if let stale = portrait?.staleFacts, !stale.isEmpty {
                StaleFactsBanner(count: stale.count)
            }

            if let cards = portrait?.cards, !cards.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: Theme.Spacing.medium)],
                    alignment: .leading,
                    spacing: Theme.Spacing.medium
                ) {
                    ForEach(cards) { card in
                        PortraitCardView(
                            card: card,
                            onConfirm: onConfirm,
                            onCorrect: onCorrect,
                            onDelete: onDelete,
                            onOpenSource: onOpenSource
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                quickFactEmptyState
            }

            NotesField(
                text: $bodyText,
                placeholder: "What is worth remembering about them?",
                isEditable: !person.isInTrash
            )
        }
        .padding(.horizontal, Theme.Spacing.large)
    }

    private var factCount: Int? {
        let count = portrait?.cards.reduce(0) { $0 + $1.values.count } ?? 0
        return count == 0 ? nil : count
    }

    /// What the Quick Facts section says before anything has been recorded.
    ///
    /// ### Why the card went
    /// It was a sparkle glyph in a tinted rounded square, a headline — "Build a better mental
    /// picture" — a line of encouragement, and four filled pastel chips, all inside a bordered card.
    /// That is the generic assistant-dashboard idiom, and this app is not that: the rest of it is
    /// quiet, and one screen adopting a different voice reads as a component borrowed from somewhere
    /// else.
    ///
    /// The worse problem was the chips. Recorded facts render as filled tinted chips too, so four
    /// suggestions — "Vegetarian", "Likes wine" — sat under a real person's name looking exactly
    /// like things somebody had actually written down about them. Nothing distinguished an offer
    /// from a record. On a screen whose entire purpose is holding true things about people, that is
    /// the one confusion worth spending layout on avoiding.
    ///
    /// A leading `plus` on each one, and a real bordered control rather than a chip, says *this adds
    /// something* instead of *this is so*. The heading above already says "Quick Facts", so the
    /// section needs a sentence, not a pep talk.
    private var quickFactEmptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Nothing recorded yet. Add what you would want to remember before seeing \(person.displayTitle) again.")
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ElephruitDesign.FlowLayout(spacing: Theme.Spacing.small, lineSpacing: Theme.Spacing.small) {
                ForEach(Self.starters, id: \.value) { seed in
                    Button {
                        onAddFact(seed)
                    } label: {
                        Label(seed.value, systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Add fact: \(seed.value)")
                }
            }
        }
    }

    private static let starters = [
        QuickFactSeed(category: .foodAndDrink, value: "Vegetarian"),
        QuickFactSeed(category: .foodAndDrink, value: "Doesn’t drink alcohol"),
        QuickFactSeed(category: .foodAndDrink, value: "Likes wine"),
        QuickFactSeed(category: .askAbout, value: "The kids"),
    ]
}

/// One card: an attribute, its current values, and how sure the app is about each.
///
/// ### Why the confidence label is beneath the value and not behind a disclosure
/// A reader who has to go looking for the caveat has already believed the number. "Estimated from
/// information shared 18 July 2026" sits in the same glance as the thing it qualifies, and only
/// appears when there is something to qualify — a confirmed fact carries no decoration at all.
struct PortraitCardView: View {
    let card: PortraitCard
    let onConfirm: (PortraitValue) -> Void
    let onCorrect: (PortraitValue) -> Void
    let onDelete: (PortraitValue) -> Void
    let onOpenSource: (UUID) -> Void

    @State private var isShowingHistory = false

    private var category: QuickFactCategory { .category(for: card.attribute) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: card.attribute.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(category.tint)
                    .frame(width: 30, height: 30)
                    .background(category.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))

                Text(card.attribute.displayName)
                    .font(Theme.Text.sectionHeader)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(card.values) { value in
                    PortraitValueRow(
                        value: value,
                        tint: category.tint,
                        onConfirm: { onConfirm(value) },
                        onCorrect: { onCorrect(value) },
                        onDelete: { onDelete(value) },
                        onOpenSource: onOpenSource
                    )
                }

                if card.historyCount > 0 {
                    Button {
                        isShowingHistory = true
                    } label: {
                        Text(card.historyCount == 1 ? "1 earlier value" : "\(card.historyCount) earlier values")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Nothing is ever overwritten — see what this used to say")
                    .popover(isPresented: $isShowingHistory) {
                        FactHistoryPopover(attribute: card.attribute, values: card.values)
                    }
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(category.tint.opacity(0.16))
        }
        .shadow(color: Theme.Colors.shadow.opacity(0.025), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.attribute.displayName)
    }
}

/// One value, with its provenance and the two things that can be done to it.
struct PortraitValueRow: View {
    let value: PortraitValue
    let tint: Color
    let onConfirm: () -> Void
    let onCorrect: () -> Void
    let onDelete: () -> Void
    let onOpenSource: (UUID) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(value.text)
                    .font(Theme.Text.rowTitle)
                    .textSelection(.enabled)

                if value.confidence.needsLabel {
                    Label(value.confidence.displayName, systemImage: value.confidence.symbolName)
                        .font(Theme.Text.chip)
                        .foregroundStyle(value.isStale ? Theme.Colors.warning : Theme.Colors.secondaryText)
                        .labelStyle(.titleAndIcon)
                }

                if value.sensitivity != .normal {
                    Image(systemName: "lock")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .help("\(value.sensitivity.displayName) — never exported")
                }

                Spacer(minLength: 0)

                if isHovering {
                    actions
                }
            }

            if let sentence = value.provenanceSentence {
                Text(sentence)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let sourceID = value.sourceItemID {
                Button {
                    onOpenSource(sourceID)
                } label: {
                    Label("Where this came from", systemImage: "arrow.up.right.square")
                        .font(Theme.Text.metadata)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.link)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Still true", action: onConfirm)
            Button("Correct this…", action: onCorrect)
            Divider()
            Button("Delete Quick Fact", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityActions {
            Button("Confirm still true", action: onConfirm)
            Button("Correct", action: onCorrect)
            Button("Delete quick fact", action: onDelete)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Button(action: onConfirm) {
                Image(systemName: "checkmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Still true — confirms without changing it")
            .accessibilityLabel("Confirm still true")

            Button(action: onCorrect) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Correct this — the previous value is kept")
            .accessibilityLabel("Correct")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this quick fact")
            .accessibilityLabel("Delete quick fact")
        }
        .font(Theme.Text.metadata)
    }

    /// Spoken as one sentence, with the hedge included.
    ///
    /// VoiceOver reading "approximately 7 to 8 years old" and then, separately, "estimated" would let
    /// a listener act on the first half. One label keeps them inseparable.
    private var accessibilityDescription: String {
        var parts = [value.text]
        if value.confidence.needsLabel { parts.append(value.confidence.displayName.lowercased()) }
        if let sentence = value.provenanceSentence { parts.append(sentence) }
        return parts.joined(separator: ". ")
    }
}

/// What a fact used to say.
struct FactHistoryPopover: View {
    let attribute: FactAttribute
    let values: [PortraitValue]

    @Environment(\.services) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("\(attribute.displayName) over time")
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)

            ForEach(values) { value in
                VStack(alignment: .leading, spacing: 1) {
                    Text(value.text)
                        .font(Theme.Text.rowSubtitle)
                    Text("Recorded \(value.observedOn.formatted(date: .abbreviated, time: .omitted))")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            Text("Correcting a fact keeps what it used to say. Nothing here was ever overwritten.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 280, alignment: .leading)
    }
}

/// Facts the app has stopped vouching for.
///
/// A banner rather than a badge on each card: the useful action is "go through these", and scattering
/// the prompt across six cards turns a five-minute tidy into a hunt.
struct StaleFactsBanner: View {
    let count: Int

    var body: some View {
        Label(
            count == 1
                ? "One fact has not been confirmed in a while."
                : "\(count) facts have not been confirmed in a while.",
            systemImage: "clock.badge.questionmark"
        )
        .font(Theme.Text.rowSubtitle)
        .foregroundStyle(Theme.Colors.secondaryText)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.Colors.warning.opacity(0.10),
            in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
        )
        .accessibilityIdentifier(AccessibilityID.People.staleFacts)
    }
}

// MARK: - Relationships

/// Who this person is connected to.
///
/// ### One relationship system, not two
/// It was two, and neither of them was arguing for itself honestly.
///
/// Children were drawn as large pink cards — a pink wash, a pink border, and a pink glyph on every
/// fact inside them — and everybody else as a small grey capsule. Two problems, and the colour is
/// the smaller one. Pink and red in this app mean *warning*, *error* and *destructive*; a section
/// where the children are the only coloured thing on the page reads, for the second it takes to
/// parse, as four things that have gone wrong. And the size difference made a claim nobody asked the
/// software to make: that a child is a major relationship and a partner is a minor one, stated in
/// card area, on every profile, whatever the family is actually like.
///
/// The defence for the split was that a child is somebody you keep a running picture of and a
/// colleague is somebody you click through to. That is a difference in *what is recorded*, not in
/// what kind of person they are — and a card that grows to fit what is known handles it without
/// anybody deciding in advance whose facts deserve room. So there is one card. It shows the person's
/// own avatar tint and no other colour, it carries whatever line of detail their record can offer,
/// and it is the same shape for a daughter, a husband, a manager and a cat.
///
/// What tells the groups apart is the heading over them and the label on each card, which is where
/// that information belongs and where it can be read.
struct PersonRelationshipsSection: View {
    @Environment(\.services) private var services

    let person: Item
    let onOpenChart: (RelationshipChartKind) -> Void
    let onOpenPerson: (UUID) -> Void

    @State private var isAddingRelationship = false
    @State private var relationshipKind: RelationshipKind = .friend
    @State private var editingRelationship: PersonRelationship?
    @State private var factTarget: Item?
    @State private var relationships: [PersonRelationship] = []
    @State private var portraits: [UUID: PersonPortrait] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            header

            if relationships.isEmpty {
                Text("Nobody linked yet. Add a partner, a child, a colleague — or type “\(person.displayTitle) son Jack” in the command bar.")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(groups, id: \.group) { entry in
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        // A heading over every group, including when there is only one. A section
                        // that names its groups only once there are two of them changes shape as
                        // somebody's record grows, and the single group it leaves unlabelled is the
                        // one whose heading would have been most informative.
                        SectionHeader(entry.group.title, count: entry.relationships.count)

                        // Wrapping rather than scrolling sideways, and adaptive rather than a fixed
                        // column count: a horizontal scroller inside a vertically scrolling pane is
                        // a second direction of scrolling nobody finds, and it hid every
                        // relationship past the fourth. The range is wide enough that the profile
                        // column lays out one, two or three abreast as it is resized without any of
                        // them becoming a slab.
                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 240, maximum: 340), spacing: Theme.Spacing.small),
                            ],
                            alignment: .leading,
                            spacing: Theme.Spacing.small
                        ) {
                            ForEach(entry.relationships, id: \.id) { relationship in
                                if let other = relationship.other {
                                    RelationshipCard(
                                        other: other,
                                        label: relationship.displayLabel,
                                        portrait: portraits[other.id],
                                        showsPrivacyMark: services?.contacts.isEnabled == true,
                                        onOpen: { onOpenPerson(other.id) },
                                        onAddDetail: { factTarget = other },
                                        onEdit: { editingRelationship = relationship }
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .task(id: person.id) { reload() }
        .sheet(isPresented: $isAddingRelationship) {
            AddRelationshipSheet(person: person, initialKind: relationshipKind) {
                isAddingRelationship = false
                reload()
            }
        }
        .sheet(item: $editingRelationship) { relationship in
            EditRelationshipSheet(person: person, relationship: relationship) {
                editingRelationship = nil
                reload()
            }
        }
        .sheet(item: $factTarget) { subject in
            AddFactSheet(
                personName: subject.displayTitle,
                onSave: { draft, confidence, sensitivity, observedOn in
                    addFact(draft, to: subject, confidence: confidence, sensitivity: sensitivity, observedOn: observedOn)
                    factTarget = nil
                },
                onCancel: { factTarget = nil }
            )
        }
    }

    /// The heading, and the two things that can be done to the section.
    ///
    /// ### Why the charts are quieter than they were
    /// A chart is worth having and is not what anybody came to this section for: the question on a
    /// profile is "who is this person connected to", and the answer is the cards. The charts answer
    /// a second question — how those connections fan out — and they answer it in a sheet. A labelled
    /// control beside *Add* said the two were equally likely next moves. An icon with a tooltip says
    /// it is there when wanted, which is what "secondary unless explicitly opened" means.
    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            SectionHeader("Relationships", count: relationships.isEmpty ? nil : relationships.count)

            Spacer()

            Menu {
                ForEach(RelationshipChartKind.allCases) { kind in
                    Button {
                        onOpenChart(kind)
                    } label: {
                        Label(kind.displayName, systemImage: kind.symbolName)
                    }
                }
            } label: {
                Label("Charts", systemImage: "point.3.connected.trianglepath.dotted")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(Theme.Text.metadata)
            .help("See these relationships as a family tree, a household, an organization, or a network")
            .accessibilityLabel("Relationship charts")
            .accessibilityIdentifier(AccessibilityID.People.charts)

            Menu {
                // The three shortcuts are pre-filled kinds rather than three different actions, and
                // they are listed in the order somebody reaches for them.
                Button {
                    relationshipKind = .child
                    isAddingRelationship = true
                } label: {
                    Label("Child…", systemImage: "figure.and.child.holdinghands")
                }

                Button {
                    relationshipKind = .partner
                    isAddingRelationship = true
                } label: {
                    Label("Partner…", systemImage: "heart")
                }

                Divider()

                Button {
                    relationshipKind = .friend
                    isAddingRelationship = true
                } label: {
                    Label("Somebody Else…", systemImage: "person.badge.plus")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(Theme.Text.metadata)
            .accessibilityLabel("Add a relationship")
        }
    }

    /// The relationships, gathered under the headings that describe them.
    ///
    /// Empty groups are absent rather than shown empty, on the same terms as the contact card: a
    /// *Work* heading with nothing under it implies homework nobody set.
    private var groups: [(group: RelationshipGroup, relationships: [PersonRelationship])] {
        Dictionary(grouping: relationships, by: { $0.kind.group })
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { (group: $0.key, relationships: $0.value) }
    }

    private func reload() {
        guard let services else { return }
        relationships = (try? services.persons.relationships(of: person)) ?? []

        // ### Which portraits are assembled, and why it is not "the children's"
        // It was the children's, because they were the only cards with room for a fact. Every card
        // has room now, so the question is which people have anything to put in one — and the answer
        // is data-driven rather than kind-driven: somebody whose record already offers a role, an
        // employer or a place has a line to show without assembling anything. Somebody who does not
        // — a six-year-old, a cat, a friend recorded as a name — is exactly who a portrait can speak
        // for, and there are never many of them.
        //
        // The cost is the same order as before: one small fetch per relationship that needs one, for
        // a set that is a person's own relationships rather than a library.
        portraits = Dictionary(uniqueKeysWithValues: relationships.compactMap { relationship in
            guard let other = relationship.other,
                  RelationshipCard.identityLine(for: other) == nil,
                  let portrait = try? services.personWorkspace.portrait(of: other)
            else { return nil }
            return (other.id, portrait)
        })
    }

    private func addFact(
        _ draft: ObservationDraft,
        to child: Item,
        confidence: FactConfidence,
        sensitivity: FactSensitivity,
        observedOn: Date
    ) {
        guard let services else { return }
        services.perform {
            try services.persons.record(
                draft,
                about: child,
                observedOn: observedOn,
                confidence: confidence,
                sensitivity: sensitivity,
                source: nil
            )
            services.noteChange(to: child)
        }
        reload()
    }
}

/// One relationship — any relationship — with whatever is known about the other person.
///
/// ### Why one card and no colour
/// It was two shapes and one of them was pink. Children got a large card with a pink wash, a pink
/// border and a pink glyph on every fact inside it; everybody else got a small grey capsule.
///
/// The colour was the plainer mistake. Pink and red mean *warning*, *error* and *destructive* in
/// this app — see ``ElephruitDesign/Theme/Colors/overdue`` and its neighbours — so a profile whose
/// only coloured element was the children read, for the moment it takes to parse, as several things
/// that had gone wrong. And the tint carried no information: everything on the card was already
/// known to be about a child from the heading above it.
///
/// The size was the more serious one. A card three times the area of a capsule says that this
/// relationship matters more than that one, on every profile, whatever the family is actually like —
/// a partner of thirty years rendered smaller than a nephew. Software should not be making that
/// claim, and it was making it in the most legible way available.
///
/// The argument for the split was that a child is somebody you keep a running picture of and a
/// colleague is somebody you click through to. That is a difference in *what is recorded*, not in
/// what kind of person they are. A card that grows to fit what is known settles it without anybody
/// deciding in advance whose facts deserve room: a colleague with a job title gets a line, a
/// six-year-old with an age and two interests gets three, and neither is a decision about them.
///
/// The only colour on the card is the person's own avatar tint, which they already carry everywhere
/// else in the app. What tells relationships apart is the heading over the group and the label on
/// the card, which is where that information can actually be read.
struct RelationshipCard: View {
    let other: Item
    let label: String
    let portrait: PersonPortrait?

    /// Whether to mark records this app holds privately.
    ///
    /// Only meaningful once an address book is connected: "not in your Contacts" is news about a
    /// record when the alternative exists, and a lock on every card in a library that has never seen
    /// Contacts is a wall of glyphs saying nothing.
    let showsPrivacyMark: Bool

    let onOpen: () -> Void
    let onAddDetail: () -> Void
    let onEdit: () -> Void

    @State private var isHovering = false

    /// The most detail a card shows before it stops being a card.
    ///
    /// Two, not four. A grid of cards is scanned rather than read, and the fourth fact about
    /// somebody's nephew is four lines of somebody else's card that never got drawn. Everything is
    /// on their own page, one click away, which is what the card is a door to.
    private static let visibleFacts = 2

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: Theme.Spacing.small) {
                    PersonAvatar(name: other.displayTitle, colorName: other.colorName, size: 32)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Theme.Spacing.tight) {
                            Text(other.displayTitle)
                                .font(.system(.callout, weight: .semibold))
                                .foregroundStyle(Theme.Colors.primaryText)
                                .lineLimit(1)

                            if showsPrivacyMark, other.personProfile?.contactsIdentifier == nil {
                                Image(systemName: "lock.shield")
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                                    .help("Held in Elephruit only — never written to your address book")
                                    .accessibilityLabel("Elephruit only")
                            }
                        }

                        if let detail {
                            Text(detail)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .lineLimit(2)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    ForEach(facts) { fact in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.tight) {
                            Image(systemName: fact.symbol)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .frame(width: 14)

                            Text(fact.text)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.primaryText)
                                .lineLimit(2)

                            if fact.isUncertain {
                                // The one place a colour still means something here, and it means
                                // what it always means: this has not been confirmed.
                                Text("Unconfirmed")
                                    .font(Theme.Text.chip)
                                    .foregroundStyle(Theme.Colors.warning)
                            }
                        }
                    }
                }
            }

            controls
        }
        .padding(Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One treatment, not a fill *and* a stroke. The card already sits inside a padded pane and
        // the grid's own gaps separate one from the next; a border on top of a fill on top of that
        // is the decoration accumulation `SourceHygieneTests` exists to keep out.
        .background(
            Theme.Colors.subtleFill,
            in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
        )
        .onHover { isHovering = $0 }
        .calmAnimation(value: isHovering)
        .help(helpText)
        .contextMenu {
            Button("Open \(other.displayTitle)", systemImage: "person.crop.circle", action: onOpen)
            Button("Add Detail…", systemImage: "plus.circle", action: onAddDetail)
            Divider()
            Button("Change Relationship…", systemImage: "pencil", action: onEdit)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(other.displayTitle), \(label)")
    }

    /// The relationship, which is also the way to change it, and the way to record something.
    ///
    /// ### Why the label *is* the control
    /// Editing and removing a relationship both worked and the only way in was an unlabelled `…`
    /// beside the relationship type drawn as static text — so the one thing on the card somebody
    /// would want to change looked like a caption, and the thing that changed it looked like
    /// decoration. Making the type itself the button says both facts in one control: this is the
    /// relationship, and this is what you press to change it. The chevron is what makes it read as
    /// editable, and the whole word is the target rather than a 24-point circle.
    ///
    /// The context menu stays as a second route rather than the only one.
    private var controls: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button(action: onEdit) {
                HStack(spacing: Theme.Spacing.hairline) {
                    Text(label)
                        .font(Theme.Text.metadata)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(Theme.Text.keyHint)
                }
                .foregroundStyle(Theme.Colors.secondaryText)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, 1)
                .background(Theme.Colors.contentBackground, in: Capsule())
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("Change or remove this relationship")
            .accessibilityLabel("Relationship with \(other.displayTitle): \(label)")
            .accessibilityHint("Change or remove this relationship")

            Spacer(minLength: 0)

            Button(action: onAddDetail) {
                Image(systemName: "plus.circle")
                    .font(Theme.Text.metadata)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.secondaryText)
            // Always offered on a card with nothing on it, because that is the card the invitation
            // is for; on hover otherwise, so a full grid is not a grid of plus signs.
            .opacity(isHovering || (detail == nil && facts.isEmpty) ? 1 : 0)
            .help("Record something about \(other.displayTitle)")
            .accessibilityLabel("Add a detail about \(other.displayTitle)")
        }
    }

    /// The one line under the name: what their record already says, or what a portrait can say.
    ///
    /// `nil` rather than an instruction. A card reading "Add age, school, and interests" on every
    /// person the user has not filled in is a grid of homework, and the invitation is already the
    /// button below it.
    private var detail: String? {
        if let line = Self.identityLine(for: other) { return line }
        if let line = portrait?.ageAndGradeLine { return line }
        if other.personProfile?.isPlaceholder == true { return "Sketch — no details yet" }
        return nil
    }

    /// Role, employer and place, from what is already stored.
    ///
    /// Static so the section can ask the same question when deciding whose portrait is worth
    /// assembling — see `PersonRelationshipsSection.reload()`. Asking it in two places with two
    /// implementations is how a card ends up blank because the fetch it needed was skipped.
    static func identityLine(for person: Item) -> String? {
        guard let profile = person.personProfile else { return nil }
        return ContactCard.identityLine(
            name: person.displayTitle,
            role: profile.roleTitle,
            organization: profile.organizationName,
            location: profile.locationText
        )
    }

    private var facts: [RelationshipCardFact] {
        guard let portrait else { return [] }
        return portrait.cards
            .filter { $0.attribute != .observedAge && $0.attribute != .schoolGrade }
            .flatMap { card in
                card.values.map {
                    RelationshipCardFact(
                        id: $0.id,
                        text: $0.text,
                        symbol: card.attribute.symbolName,
                        isUncertain: $0.confidence.needsLabel
                    )
                }
            }
            .prefix(Self.visibleFacts)
            .map { $0 }
    }

    private var helpText: String {
        if other.personProfile?.isPlaceholder == true {
            return "\(other.displayTitle) — a lightweight record with no details yet"
        }
        return "Open \(other.displayTitle)"
    }
}

private struct RelationshipCardFact: Identifiable {
    let id: UUID
    let text: String
    let symbol: String
    let isUncertain: Bool
}

// MARK: - Timeline

/// Everything that has happened, newest first.
struct PersonTimelineSection: View {
    let entries: [PersonTimelineEntry]
    @Binding var filter: TimelineGrouping.Filter
    let dateProvider: any DateProvider
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                SectionHeader("History", count: filtered.count)
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(TimelineGrouping.Filter.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Filter the history")
            }

            if filtered.isEmpty {
                EmptyStateView(
                    symbolName: "clock",
                    headline: entries.isEmpty ? "Nothing yet" : "Nothing of that kind",
                    message: entries.isEmpty
                        ? "Notes, meetings, and tasks that mention this person appear here automatically."
                        : "Try a different filter."
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(grouped, id: \.month) { group in
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                        Text(group.month.formatted(.dateTime.month(.wide).year()))
                            .font(Theme.Text.sectionHeader)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .padding(.top, Theme.Spacing.small)

                        ForEach(group.entries) { entry in
                            TimelineEntryRow(entry: entry, dateProvider: dateProvider) { onOpen(entry.id) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .accessibilityIdentifier(AccessibilityID.People.timeline)
    }

    private var filtered: [PersonTimelineEntry] {
        entries.filter(filter.matches)
    }

    private var grouped: [(month: Date, entries: [PersonTimelineEntry])] {
        TimelineGrouping.byMonth(filtered, calendar: dateProvider.calendar)
    }
}

struct TimelineEntryRow: View {
    let entry: PersonTimelineEntry
    let dateProvider: any DateProvider
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                VStack(spacing: 0) {
                    Image(systemName: entry.kind.symbolName)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(entry.isContact ? Theme.Colors.selection : Theme.Colors.secondaryText)
                        .frame(width: Theme.Size.rowGlyph)
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    HStack(spacing: Theme.Spacing.small) {
                        Text(entry.title)
                            .font(entry.isOpen ? Theme.Text.rowTitleEmphasised : Theme.Text.rowTitle)
                            .lineLimit(1)

                        if entry.isPromise {
                            Label("task", systemImage: "checkmark.circle")
                                .font(Theme.Text.chip)
                                .foregroundStyle(Theme.Colors.selection)
                                .labelStyle(.titleAndIcon)
                        }

                        Spacer(minLength: Theme.Spacing.small)

                        Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                    }

                    Text(entry.provenanceLine)
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    if let excerpt = entry.excerpt {
                        Text(excerpt)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .lineLimit(2)
                    }

                    if !entry.tagSlugs.isEmpty {
                        TagChipRow(slugs: entry.tagSlugs)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.tight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title). \(entry.provenanceLine). \(entry.date.formatted(date: .abbreviated, time: .omitted))")
        .accessibilityAddTraits(.isButton)
    }
}
