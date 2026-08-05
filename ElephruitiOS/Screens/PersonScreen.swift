import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// One record: who they are, what is open with them, and what has happened.
///
/// The Mac gives a record a workspace with a portrait pane, a timeline pane, an inspector and
/// relationship charts side by side. A phone reads top to bottom, so the same material is
/// ordered by how often it answers the question that opened the screen: what do I know about
/// this person, what do I owe them, and what happened last. The charts stay on the Mac — a
/// relationship graph is a thing you explore with a pointer, and a 400-point-wide one would be
/// a picture of a graph rather than a graph.
///
/// Every fact comes from `PersonWorkspaceService`, which is where the Mac's portrait comes
/// from, so a fact shown here is the same fact with the same confidence and the same staleness.
struct PersonScreen: View {
    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    let personID: UUID

    @State private var person: Item?
    @State private var portrait: PersonPortrait?
    @State private var context: PersonSidebarContext?
    @State private var timeline: [PersonTimelineEntry] = []
    @State private var loadError: String?
    /// Their photograph, once Contacts has answered. Held here rather than read in `body` for the
    /// reason given on `ContactPhotoStore`.
    @State private var photo: Data?
    /// What sort of record this is, read once with everything else rather than in `body`.
    @State private var recordType: RecordType = .person
    /// The groups this person is in, read with everything else.
    @State private var groups: [PersonGroupSummary] = []
    @State private var isEditingGroups = false

    /// How much of a long history a phone shows before it stops being a summary.
    private static let timelineLimit = 40

    var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.Colors.warning)
            }

            if let person {
                headerSection(person)
                groupsSection(person)
                factsSection
                openWorkSection
                relatedSection
                timelineSection
                notesSection(person)
            } else if loadError == nil {
                EmptyStateView(
                    symbolName: "person",
                    headline: "Record not found",
                    message: "It may have been deleted or merged into another record."
                )
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(person?.displayTitle ?? "Record")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadKey) { reload() }
        .accessibilityIdentifier("person.screen")
    }

    private var reloadKey: String {
        "\(services?.changeToken ?? 0)-\(personID.uuidString)"
    }

    // MARK: - Sections

    /// The circles this person is in, and the way into changing them.
    ///
    /// ### Why the smart ones are shown but not offered
    /// A fixed group has members somebody chose, so a toggle writes one. A smart group's membership
    /// is whatever its query matches right now — there is nothing to write, and a toggle that
    /// silently did nothing would be worse than no toggle. So both are drawn, because both are true
    /// of this person, and only the fixed ones are editable. The editor says which is which rather
    /// than leaving a disabled row to be read as broken.
    @ViewBuilder
    private func groupsSection(_ person: Item) -> some View {
        Section("Groups") {
            if groups.isEmpty {
                Button {
                    isEditingGroups = true
                } label: {
                    Label("Add to a group", systemImage: "plus.circle")
                }
            } else {
                ForEach(groups) { group in
                    Button {
                        shell.push(.records(.group(id: group.id)))
                    } label: {
                        HStack(spacing: Theme.Spacing.medium) {
                            GroupTile(symbolName: group.symbolName, colorName: group.colorName, size: .small)
                            Text(group.name)
                                .foregroundStyle(Theme.Colors.primaryText)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button("Edit Groups", systemImage: "pencil") { isEditingGroups = true }
            }
        }
        .sheet(isPresented: $isEditingGroups) {
            GroupMembershipSheet(person: person) { reload() }
        }
    }

    /// Who they are, led by their face.
    ///
    /// It was the record type's SF Symbol at hero size — the same outline of a generic head on every
    /// person in the library, which is a picture of the *category* at the top of a page about an
    /// individual. The list already draws people as themselves; a detail screen that did not was the
    /// one place the app forgot whose page it was on.
    private func headerSection(_ person: Item) -> some View {
        Section {
            HStack(spacing: Theme.Spacing.medium) {
                // The same rule the list row applies, for the same reason: initials are the picture
                // of somebody with a name, and a car is not somebody with a name.
                switch recordType {
                case .person, .pet:
                    Avatar(
                        name: person.displayTitle,
                        diameter: Theme.Size.iconTileLarge,
                        tint: Theme.Palette.color(named: person.colorName),
                        photo: photo
                    )
                case .vehicle, .organization, .other:
                    IconTile(
                        systemImage: recordType.symbolName,
                        tint: Theme.Palette.color(named: person.colorName),
                        size: .large
                    )
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text(person.displayTitle)
                        .font(Theme.Text.title)
                    if let line = portrait?.ageAndGradeLine {
                        Text(line)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.Spacing.tight)

            if !person.tagSlugs.isEmpty {
                TagChipRow(slugs: person.tagSlugs, limit: 6)
            }
        }
    }

    /// What is known, most-confident first, with the stale ones saying so.
    ///
    /// A fact the app is no longer sure of is worse than a missing one, which is why
    /// `isStale` is drawn rather than quietly ignored: the Mac earns trust by admitting when
    /// something was last confirmed a long time ago, and a phone that hid it would be a
    /// second, more confident app over the same data.
    @ViewBuilder
    private var factsSection: some View {
        if let cards = portrait?.cards, !cards.isEmpty {
            Section("Known") {
                ForEach(cards) { card in
                    ForEach(card.values) { value in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                            Text(card.attribute.displayName)
                                .font(Theme.Text.rowSubtitle)
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .frame(width: 110, alignment: .leading)

                            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                                Text(value.text)
                                    .font(Theme.Text.rowTitle)
                                if value.isStale, let clock = services?.dateProvider {
                                    Text(
                                        "Last confirmed "
                                            + RelativeDay.text(for: value.lastConfirmedOn, using: clock)
                                    )
                                    .font(Theme.Text.metadata)
                                    .foregroundStyle(Theme.Colors.warning)
                                }
                            }

                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    /// What is still owed. Above the history deliberately: the past is reference, and this is
    /// the part that can still be acted on.
    @ViewBuilder
    private var openWorkSection: some View {
        if let open = context?.openItems, !open.isEmpty {
            Section("Open") {
                ForEach(open) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    /// Who and what this record connects to. The Mac draws these as charts; a phone draws the
    /// same edges as rows you can walk, which is the part of a graph a thumb can actually use.
    @ViewBuilder
    private var relatedSection: some View {
        if let context, !context.relatedPeople.isEmpty || !context.sharedProjects.isEmpty {
            Section("Connected") {
                ForEach(context.relatedPeople, id: \.id) { related in
                    Button {
                        shell.push(.person(related.id))
                    } label: {
                        HStack(spacing: Theme.Spacing.medium) {
                            Image(systemName: "person")
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .frame(width: Theme.Size.rowGlyph)
                            Text(related.name)
                                .foregroundStyle(Theme.Colors.primaryText)
                            Spacer(minLength: 0)
                            Text(related.label)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                ForEach(context.sharedProjects, id: \.id) { project in
                    Button {
                        shell.push(.project(project.id))
                    } label: {
                        Label(project.name, systemImage: "folder")
                            .foregroundStyle(Theme.Colors.primaryText)
                            .frame(minHeight: 44)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var timelineSection: some View {
        if !timeline.isEmpty {
            Section("History") {
                ForEach(timeline.prefix(Self.timelineLimit)) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    /// One timeline entry, wherever it appears. Open work and history are the same rows read
    /// with different questions, so they are the same row.
    private func entryRow(_ entry: PersonTimelineEntry) -> some View {
        Button {
            shell.push(MobileShellModel.route(for: entry.kind, id: entry.id))
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                Image(systemName: entry.kind.symbolName)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: Theme.Size.rowGlyph)

                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text(entry.title)
                        .font(Theme.Text.rowTitle)
                        .foregroundStyle(Theme.Colors.primaryText)
                        .lineLimit(2)

                    if let excerpt = entry.excerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let clock = services?.dateProvider {
                    Text(RelativeDay.text(for: entry.date, using: clock))
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func notesSection(_ person: Item) -> some View {
        if !person.body.isEmpty {
            Section("Notes") {
                Text(person.body)
                    .font(Theme.Text.editorBody)
            }
        }
    }

    // MARK: - Loading

    private func reload() {
        guard let services else { return }
        do {
            guard let record = try services.items.item(id: personID) else {
                person = nil
                return
            }
            person = record
            recordType = services.records.type(of: record)
            portrait = try services.personWorkspace.portrait(of: record)
            timeline = try services.personWorkspace.timeline(for: record)
            context = try services.personWorkspace.sidebar(for: record)
            groups = try services.personGroups.membership().groups(for: record.id)
            loadError = nil

            // After the page is on screen, never before it: a face is worth waiting a frame for and
            // is not worth holding the record's own detail back for.
            let identifier = record.personProfile?.contactsIdentifier
            photo = services.contacts.cachedPhoto(forContactIdentifier: identifier)
            if photo == nil {
                Task { photo = await services.contacts.photo(forContactIdentifier: identifier) }
            }
        } catch {
            loadError = error.summary
        }
    }
}
