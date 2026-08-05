import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftData
import SwiftUI

/// One smart list: a rule over the library, and everything currently satisfying it.
///
/// Built-in and saved lists are the same screen because they are the same idea — a
/// `TaskFilter` with a name — and the only difference is where the filter came from. Splitting
/// them would have produced two screens that had to be kept agreeing about what a rule means.
///
/// The rule is stated under the title rather than hidden behind an info button. A smart list
/// that shows six of your eleven overdue reminders and does not say why is a list you stop
/// trusting; naming the rule is what lets a surprising result be read as a surprising *rule*.
struct ReminderListScreen: View {
    enum Source: Hashable {
        case smartList(UUID)
        case builtIn(String)
    }

    @Environment(\.services) private var services
    @Environment(MobileShellModel.self) private var shell

    let source: Source

    @State private var items: [Item] = []
    @State private var title = "List"
    @State private var summary: String?
    @State private var symbolName = "line.3.horizontal.decrease.circle"
    @State private var isUnderstood = true
    @State private var loadError: String?

    var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.Colors.warning)
            }

            if let summary {
                Section {
                    Label(summary, systemImage: symbolName)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }

            // A rule this build cannot evaluate is said out loud. The filter itself already
            // fails closed — an unrecognised rule shows less rather than more — and this is the
            // other half of that promise: the list says it is showing less.
            if !isUnderstood {
                Section {
                    Label(
                        "Part of this list's rule was written by a newer version and is being "
                            + "ignored, so this list may be showing less than it should.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.warning)
                }
            }

            if items.isEmpty, loadError == nil {
                EmptyStateView(
                    symbolName: symbolName,
                    headline: "Nothing matches",
                    message: "Nothing in the library satisfies this list's rule right now.",
                    tone: .noResults
                )
                .listRowBackground(Color.clear)
                .frame(maxWidth: .infinity)
            } else {
                ForEach(items) { item in
                    MobileItemRow(
                        item: item,
                        onToggleCompletion: item.kind.supportsStatus
                            ? { toggleCompletion(of: item) }
                            : nil
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        shell.push(MobileShellModel.route(for: item.kind, id: item.id))
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadKey) { reload() }
        .accessibilityIdentifier("reminderList.screen")
    }

    private var reloadKey: String {
        "\(services?.changeToken ?? 0)-\(String(describing: source))"
    }

    // MARK: - Loading

    private func reload() {
        guard let services else { return }

        guard let filter = resolveFilter(using: services) else {
            loadError = "This list could not be found."
            items = []
            return
        }

        // An unconstrained rule would match the whole library under somebody's chosen name,
        // which is the one wrong answer a smart list can give — the Mac refuses it and so does
        // this.
        guard !filter.isUnconstrained else {
            items = []
            summary = "This list has no rules yet, so it matches nothing."
            loadError = nil
            return
        }

        isUnderstood = filter.unrecognisedRules.isEmpty

        var query = ItemQuery()
        query.kinds = ItemKind.workItemKindSet
        query.statuses = filter.includesResolved ? [] : [.open]
        query.sort = .dueSoonestFirst

        do {
            let clock = services.dateProvider
            let candidates = try services.items.items(matching: query)
            items = candidates.filter {
                filter.matches($0.taskFacts(), now: clock.now, calendar: clock.calendar)
            }
            loadError = nil
        } catch {
            loadError = error.summary
        }
    }

    /// The rule behind this list, and the words that go with it.
    private func resolveFilter(using services: AppServices) -> TaskFilter? {
        switch source {
        case .builtIn(let id):
            guard let list = BuiltInSmartList.list(id: id) else { return nil }
            title = list.title
            summary = list.hint
            symbolName = list.symbolName
            return list.filter

        case .smartList(let id):
            let descriptor = FetchDescriptor<SavedSearch>(
                predicate: #Predicate { $0.id == id && $0.deletedAt == nil }
            )
            guard let saved = try? services.context.fetch(descriptor).first,
                  let filter = saved.taskFilter
            else { return nil }
            title = saved.name
            // The query string the user typed *is* the rule, in their own words. A generated
            // English restatement of a filter would be a second description that could drift
            // from the one they wrote.
            summary = saved.queryString.isEmpty ? nil : saved.queryString
            symbolName = saved.symbolName ?? "line.3.horizontal.decrease.circle"
            return filter
        }
    }

    private func toggleCompletion(of item: Item) {
        guard let services else { return }
        services.perform {
            try services.items.toggleCompletion(item)
            services.noteChange(to: item)
        }
        reload()
    }
}
