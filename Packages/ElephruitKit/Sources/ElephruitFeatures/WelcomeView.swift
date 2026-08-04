import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The first launch, oriented in three lines.
///
/// The app had no first-run state at all: an empty library landed on an empty Today, and the
/// three keystrokes the whole product is built around — capture, search, the palette — were
/// discoverable only by reading the menus. This says them once, over the empty library only,
/// and never again after any action or dismissal. It is a card, not a tour: the product's own
/// principles rule out an app that makes you watch it introduce itself.
struct WelcomeView: View {
    @Environment(\.services) private var services

    let navigation: NavigationModel

    /// App-wide, not per window: being welcomed twice is being interrupted once.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    /// `nil` until the emptiness check has run — nothing shows before it has.
    @State private var libraryIsEmpty: Bool?

    var body: some View {
        Group {
            if !hasSeenWelcome, libraryIsEmpty == true {
                card
            }
        }
        .task {
            guard !hasSeenWelcome, libraryIsEmpty == nil, let services else { return }
            var query = ItemQuery()
            query.scope = .all
            libraryIsEmpty = ((try? services.items.items(matching: query)) ?? []).isEmpty
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            HStack(spacing: Theme.Spacing.medium) {
                IconTile(systemImage: "brain.head.profile", tint: Theme.Colors.selection, size: .large)
                VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                    Text("Welcome to Elephruit")
                        .font(Theme.Text.title)
                    Text("Your working memory, in one place, on this Mac.")
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                shortcutRow(
                    keys: ["⌘", "⇧", "J"],
                    text: "Capture a thought from anywhere — even from another app."
                )
                shortcutRow(
                    keys: ["⌘", "F"],
                    text: "Search everything you have ever put in."
                )
                shortcutRow(
                    keys: ["⌘", "K"],
                    text: "Do anything by name, from the command palette."
                )
            }

            HStack {
                if services?.isDevelopmentMode == true {
                    Button("Load Sample Data") {
                        services?.loadSampleData()
                        dismiss()
                    }
                }

                Spacer()

                Button("Write a First Note") {
                    createFirstNote()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                .fill(Theme.Colors.contentBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                .strokeBorder(Theme.Colors.separator)
        )
        .elevation(.floating)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .padding(Theme.Spacing.small)
            .help("Dismiss")
            .accessibilityLabel("Dismiss the welcome")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.card")
    }

    private func shortcutRow(keys: [String], text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            KeyHint(keys: keys)
            Text(text)
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func createFirstNote() {
        defer { dismiss() }
        guard let services else { return }
        services.perform {
            let note = try services.items.create(ItemDraft(kind: .note, title: ""))
            navigation.select(.kind(.note))
            navigation.selectItem(note.id)
            services.noteChange(to: note)
        }
    }

    private func dismiss() {
        hasSeenWelcome = true
    }
}
