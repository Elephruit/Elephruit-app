import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// Somebody's addresses, numbers, and sites, grouped by which side of their life they belong to.
///
/// ### Why this section had to exist
/// The page could *use* a person's email — the quick actions dial, write, and map from it — but it
/// never showed it. Reading somebody's address off the screen, or copying a number into another app,
/// meant expanding the address-book provenance list, which is a record of where a value came from
/// rather than a card of what the values are. Those are different questions and only one of them is
/// asked daily.
///
/// ### Why grouping is by affinity rather than by kind
/// "Which of these two numbers is her work one" is the question people actually have. Grouping by
/// kind — all emails, then all numbers — answers a question nobody asks and buries that one. See
/// ``ContactAffinity``.
///
/// ### Editing, and what happens to a linked record
/// These values were read-only for a long time, on the grounds that they belong to the address book
/// for anybody who has linked one and that an edit a refresh would silently discard is worse than no
/// edit at all. The second half of that is still true; the conclusion no longer follows, because the
/// edit is now offered back to the address book rather than only kept here. An unlinked person is
/// simply edited. A linked one is edited here and then asked about there — see
/// ``ContactWriteBackSheet``, which is the only thing in the app that can change a system contact and
/// does nothing at all without a click.
struct PersonContactSection: View {
    let person: Item
    let onAction: (ContactActionRequest) -> Void
    let onEdit: () -> Void

    var body: some View {
        // The header stays even with nothing under it: a person with no number at all is exactly who
        // needs the Add button, and hiding the whole section from them was why there was no way in.
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack {
                SectionHeader("Contact", count: details.count)

                Button(action: onEdit) {
                    Label(details.isEmpty ? "Add" : "Edit", systemImage: details.isEmpty ? "plus" : "pencil")
                }
                .buttonStyle(.borderless)
                .font(Theme.Text.metadata)
                .help("Edit these details")
                .accessibilityIdentifier(AccessibilityID.People.editContactDetails)
            }

            if groups.isEmpty {
                Text("No address, number, or site recorded.")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }

            // ### Why a grid and not a stack of rows
            // Because a label column that is *nearly* aligned is worse than one that is not aligned
            // at all. Each row used to set its own 120-point frame, so the values lined up only
            // while every label happened to be shorter than that — and the moment one was not, the
            // whole column stepped sideways for one row. A `Grid` measures the widest label once and
            // gives every row the same answer, at any text size and in any language.
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    ContactAffinityChip(group.affinity)

                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.medium, verticalSpacing: Theme.Spacing.small) {
                        ForEach(group.details) { detail in
                            ContactDetailRow(detail: detail) { act(on: detail) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.People.contactDetails)
    }

    private var details: [ContactDetail] {
        person.personProfile?.contactDetails() ?? []
    }

    private var groups: [ContactDetailGroup] {
        ContactCard.groups(from: details)
    }

    /// Opens the one channel this detail supports, through the same confirmation sheet the header's
    /// quick actions use — so a click here can no more silently ring somebody than a click there can.
    private func act(on detail: ContactDetail) {
        guard let channel = channel(for: detail.kind) else { return }
        let destination = ContactDestination(
            label: detail.label,
            value: detail.value,
            source: detail.kind.destinationSource
        )
        onAction(ContactActionRequest(channel: channel, person: person, destinations: [destination]))
    }

    /// Email writes, a number rings, an address maps, a site opens. FaceTime and Messages stay in the
    /// header, where the user picks the channel first — a number in a card has no way of saying which
    /// of the three ways of using it was meant.
    private func channel(for kind: ContactDetailKind) -> ContactChannel? {
        switch kind {
        case .email: .email
        case .phone: .call
        case .address: .maps
        case .website: .web
        }
    }
}

/// One line of a person's card: label, value, and the one thing that can be done with it.
///
/// The value is selectable so it can be copied without any action being taken at all, which is what
/// somebody reading an address onto a form actually wants.
private struct ContactDetailRow: View {
    let detail: ContactDetail
    let onUse: () -> Void

    @State private var isHovering = false

    var body: some View {
        GridRow {
            Label(detail.displayLabel, systemImage: detail.kind.symbolName)
                .font(Theme.Text.metadata)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(detail.affinity.color)
                .gridColumnAlignment(.leading)

            // The value and its one action, together. Beside the value rather than at the pane's
            // trailing edge: a wide detail pane would otherwise strand the button half a screen from
            // the thing it acts on, which is both a longer mouse journey and a weaker claim about
            // what it does.
            //
            // Revealed on hover, because a row of small glyphs down the right of every value is
            // chrome the eye has to step over to read the numbers — which is what the section is
            // for. It stays in the layout while hidden, so nothing shifts when the pointer arrives,
            // and it is always present for VoiceOver and for the keyboard.
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(detail.displayValue)
                    .font(Theme.Text.rowSubtitle)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onUse) {
                    Image(systemName: useSymbol)
                        .font(Theme.Text.metadata)
                }
                .buttonStyle(.borderless)
                .opacity(isHovering ? 1 : 0)
                .help(useDescription)
                .accessibilityLabel(useDescription)

                Spacer(minLength: 0)
            }
            .gridColumnAlignment(.leading)
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .calmAnimation(value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(detail.affinity.displayName) \(detail.kind.displayName.lowercased()), "
                + "\(detail.displayLabel), \(detail.displayValue)"
        )
    }

    private var useSymbol: String {
        switch detail.kind {
        case .email: "envelope"
        case .phone: "phone"
        case .address: "map"
        case .website: "arrow.up.forward.app"
        }
    }

    private var useDescription: String {
        switch detail.kind {
        case .email: "Write to this address"
        case .phone: "Call this number"
        case .address: "Open in Maps"
        case .website: "Open this site"
        }
    }
}
