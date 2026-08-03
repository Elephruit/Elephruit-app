import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Context that is useful beside a person record without repeating the record itself.
struct RecordContextSidebar: View {
    @Environment(\.services) private var services

    let person: Item
    let navigation: NavigationModel

    @State private var context: PersonSidebarContext?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if let context, !context.isEmpty {
                    if !context.celebrations.isEmpty {
                        InspectorSection("Coming up") {
                            ForEach(context.celebrations) { entry in
                                Text(entry.summary).font(Theme.Text.rowSubtitle)
                            }
                        }
                    }

                    if !context.upcoming.isEmpty {
                        InspectorSection("Scheduled") {
                            ForEach(context.upcoming.prefix(5)) { entry in
                                linkRow(entry.title, systemImage: entry.kind.symbolName) {
                                    navigation.selectItem(entry.id)
                                }
                            }
                        }
                    }

                    if !context.openItems.isEmpty {
                        InspectorSection("Tasks") {
                            ForEach(context.openItems.prefix(6)) { entry in
                                linkRow(entry.title, systemImage: entry.kind.symbolName) {
                                    navigation.selectItem(entry.id)
                                }
                            }
                        }
                    }

                    if !context.sharedProjects.isEmpty {
                        InspectorSection("Shared projects") {
                            ForEach(context.sharedProjects) { project in
                                linkRow(project.name, systemImage: "square.stack.3d.up") {
                                    navigation.selectItem(project.id)
                                }
                            }
                        }
                    }

                    if !context.staleFacts.isEmpty {
                        InspectorSection("Worth checking") {
                            ForEach(context.staleFacts, id: \.id) { fact in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("\(fact.attribute.displayName): \(fact.value)")
                                        .font(Theme.Text.rowSubtitle)
                                    Text("Last confirmed \(fact.lastConfirmedOn.formatted(date: .abbreviated, time: .omitted))")
                                        .font(Theme.Text.metadata)
                                        .foregroundStyle(Theme.Colors.tertiaryText)
                                }
                            }
                        }
                    }
                } else {
                    EmptyStateView(
                        symbolName: "sidebar.trailing",
                        headline: "Nothing outstanding",
                        message: "What is scheduled, open, or worth checking appears here. The record page holds everything else."
                    )
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .accessibilityIdentifier(AccessibilityID.Records.contextSidebar)
        .task(id: person.id) { reload() }
        .onChange(of: services?.changeToken) { _, _ in reload() }
    }

    private func reload() {
        context = try? services?.personWorkspace.sidebar(for: person)
    }

    private func linkRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.Text.rowSubtitle)
                .lineLimit(1)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
