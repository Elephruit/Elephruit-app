import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// A timeline item read in the context that made it meaningful: the person's page.
///
/// Opening a note or promise used to replace the person with the universal item editor. Besides
/// exposing controls that had nothing to do with the moment, that navigation had no visible way
/// home. This sheet leaves the portrait underneath and makes returning the primary action.
struct PersonTimelineDetailSheet: View {
    @Environment(\.services) private var services

    let entry: PersonTimelineEntry
    let personID: UUID
    let personName: String
    let onClose: () -> Void

    @State private var item: Item?
    @State private var status: ItemStatus = .none
    @State private var failure: AppError?
    @State private var isConfirmingDeletion = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    hero
                    metadata

                    if !bodyText.isEmpty {
                        detailCard(title: entry.kind == .note ? "Note" : "What was recorded", symbol: "text.alignleft") {
                            Text(bodyText)
                                .font(Theme.Text.editorBody)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if !people.isEmpty {
                        detailCard(title: "People", symbol: "person.2.fill") {
                            HStack(spacing: Theme.Spacing.small) {
                                ForEach(people, id: \.id) { person in
                                    Label(person.name, systemImage: "person.crop.circle.fill")
                                        .font(Theme.Text.chip)
                                        .foregroundStyle(accent)
                                        .padding(.horizontal, Theme.Spacing.small)
                                        .frame(height: 28)
                                        .background(accent.opacity(0.1), in: Capsule())
                                }
                            }
                        }
                    }

                    if !visibleTags.isEmpty {
                        detailCard(title: "Tags", symbol: "tag.fill") {
                            TagChipRow(slugs: visibleTags)
                        }
                    }

                    if let failure {
                        Label(failure.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.overdue)
                    }
                }
                .padding(Theme.Spacing.section)
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 540)
        .background(Theme.Colors.windowBackground)
        .task(id: entry.id) { load() }
        .confirmationDialog(
            "Move this (entry.kind.displayName.lowercased()) to Trash?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { moveToTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can restore it later from Trash.")
        }
    }

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Label("Back to \(personName)", systemImage: "chevron.left")
                    .font(.system(.body, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.selection)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Text(entry.kind.displayName)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
        }
        .padding(.horizontal, Theme.Spacing.section)
        .frame(height: 56)
        .background(Theme.Colors.contentBackground)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: heroSymbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 52, height: 52)
                .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 15))

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(accent)
                Text(entry.title)
                    .font(.system(.title2, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.provenanceLine)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer()
        }
        .padding(Theme.Spacing.large)
        .background(
            LinearGradient(
                colors: [accent.opacity(0.11), accent.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accent.opacity(0.14))
        }
    }

    private var metadata: some View {
        HStack(spacing: Theme.Spacing.medium) {
            metadataTile(
                title: "When",
                value: entry.date.formatted(date: .abbreviated, time: entry.kind == .interaction ? .shortened : .omitted),
                symbol: "calendar"
            )

            if entry.kind.isWorkItem {
                metadataTile(title: "Status", value: status.displayName, symbol: status.symbolName)
            } else if let interactionKind = entry.interactionKind {
                metadataTile(title: "Type", value: interactionKind.displayName, symbol: interactionKind.symbolName)
            } else {
                metadataTile(title: "From", value: personName, symbol: "person.crop.circle")
            }

            if let dueAt = item?.dueAt {
                metadataTile(
                    title: "Due",
                    value: dueAt.formatted(date: .abbreviated, time: .omitted),
                    symbol: "flag"
                )
            }
        }
    }

    private func metadataTile(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: symbol)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                Text(value)
                    .font(.system(.callout, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Colors.separator.opacity(0.6))
        }
    }

    private func detailCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label(title, systemImage: symbol)
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(Theme.Colors.primaryText)
            content()
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.Colors.separator.opacity(0.6))
        }
    }

    private var footer: some View {
        HStack {
            if entry.isPromise || entry.kind.isWorkItem {
                if status == .completed {
                    Label("Completed", systemImage: "checkmark.circle.fill")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Theme.Palette.green.color)
                } else {
                    Button("Mark Complete", systemImage: "checkmark.circle") { complete() }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                }
            }

            Spacer()

            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                isConfirmingDeletion = true
            }
            .buttonStyle(.borderless)

            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Spacing.section)
        .frame(height: 60)
        .background(Theme.Colors.contentBackground)
    }

    private var bodyText: String {
        item?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? entry.excerpt ?? ""
    }

    private var people: [PersonReference] {
        [PersonReference(id: personID, name: personName)] + entry.otherPeople.filter { $0.id != personID }
    }

    /// The tags worth showing as chips.
    ///
    /// The marker that made this a task owed to somebody is already said in words by the eyebrow
    /// above, so repeating it as a chip is the same fact twice. Every spelling of the marker is
    /// dropped — see ``TagConventions/owed``.
    private var visibleTags: [String] {
        entry.tagSlugs.filter { !TagConventions.marksOwed($0) && !$0.hasPrefix("interaction/") }
    }

    private var eyebrow: String {
        if entry.isPromise { return "Task" }
        if entry.kind == .interaction { return "Interaction" }
        return entry.kind.displayName
    }

    private var heroSymbol: String {
        entry.isPromise ? "checkmark.circle.fill" : entry.kind.symbolName
    }

    private var accent: Color {
        if entry.isPromise { return Theme.Palette.green.color }
        switch entry.kind {
        case .note: return Theme.Palette.blue.color
        case .interaction, .meeting: return Theme.Palette.purple.color
        case .task, .reminder: return Theme.Palette.green.color
        default: return Theme.Colors.selection
        }
    }

    private func load() {
        guard let services else { return }
        do {
            item = try services.items.item(id: entry.id)
            status = item?.status ?? (entry.isOpen ? .open : .none)
            failure = nil
        } catch {
            failure = error
        }
    }

    private func complete() {
        guard let services, let item else { return }
        do {
            _ = try services.tasks.complete(item)
            status = .completed
            services.noteChange(to: item)
        } catch {
            failure = error
        }
    }

    private func moveToTrash() {
        guard let services, let item else { return }
        do {
            try services.undo.moveToTrash([item])
            services.noteChange(to: item)
            onClose()
        } catch {
            failure = error
        }
    }
}
