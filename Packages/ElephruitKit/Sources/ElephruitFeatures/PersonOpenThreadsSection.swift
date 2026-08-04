import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// What is open between you and this person, on the page itself.
///
/// The answer used to live only in the context inspector — behind ⌥⌘I, and until recently behind
/// a width threshold the default window could not meet. A person's page exists to answer two
/// questions, "who is this" and "what do we owe each other", and the second was the hidden one.
/// This is the compact form: open reminders, what is scheduled, shared projects. The inspector
/// keeps the fuller version, with celebrations and facts worth re-confirming.
struct PersonOpenThreadsSection: View {
    @Environment(\.services) private var services

    let person: Item
    let navigation: NavigationModel

    @State private var context: PersonSidebarContext?

    var body: some View {
        Group {
            if let context, hasThreads(context) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    SectionHeader(
                        "Open Threads",
                        count: context.openItems.count + context.upcoming.count
                    )

                    if !context.openItems.isEmpty {
                        threadRows(
                            context.openItems.prefix(5).map { ($0.id, $0.title, $0.kind.symbolName) }
                        )
                    }

                    if !context.upcoming.isEmpty {
                        threadRows(
                            context.upcoming.prefix(3).map { ($0.id, $0.title, "calendar") }
                        )
                    }

                    if !context.sharedProjects.isEmpty {
                        HStack(spacing: Theme.Spacing.tight) {
                            ForEach(context.sharedProjects.prefix(4)) { project in
                                Chip(project.name, systemImage: "square.stack.3d.up", tint: Theme.Colors.selection)
                                    .onTapGesture { navigation.selectItem(project.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.large)
            }
        }
        .task(id: person.id) { load() }
        .accessibilityIdentifier("person.openThreads")
    }

    private func hasThreads(_ context: PersonSidebarContext) -> Bool {
        !context.openItems.isEmpty || !context.upcoming.isEmpty || !context.sharedProjects.isEmpty
    }

    private func threadRows(_ rows: [(id: UUID, title: String, symbol: String)]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            ForEach(rows, id: \.id) { row in
                Button {
                    navigation.selectItem(row.id)
                } label: {
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: row.symbol)
                            .frame(width: Theme.Size.rowGlyph)
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Text(row.title)
                            .font(Theme.Text.rowSubtitle)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverHighlight()
            }
        }
    }

    private func load() {
        guard let services else { return }
        context = try? services.personWorkspace.sidebar(for: person)
    }
}
