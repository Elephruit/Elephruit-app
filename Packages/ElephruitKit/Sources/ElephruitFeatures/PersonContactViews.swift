import AppKit
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
            //
            // ### And why *one* grid rather than one per group
            // Because a grid only aligns what is inside it. Personal and Work each had their own,
            // so the two label columns were measured separately and landed at two different
            // x-positions — with a tinted pill floating above each, outside both grids, aligned to
            // neither. Three left edges in a section whose whole job is to be a tidy column of
            // facts.
            //
            // The headings are rows of this grid now, spanning both cells. Every label in the
            // section is measured together, every value starts at the same place, and the category
            // sits over its rows rather than beside nothing.
            Grid(
                alignment: .leadingFirstTextBaseline,
                horizontalSpacing: Theme.Spacing.medium,
                verticalSpacing: Theme.Spacing.small
            ) {
                ForEach(groups) { group in
                    GridRow {
                        // The padding is inside the heading rather than on the `GridRow`. A modifier
                        // applied to a row turns it into an ordinary view, and an ordinary view in a
                        // `Grid` is one cell rather than a row — which would put the heading in the
                        // label column and start a fresh measurement for everything under it, in the
                        // section whose whole point is that everything is measured together.
                        ContactAffinityHeading(
                            group.affinity,
                            // The heading belongs to what follows it, not to what precedes it.
                            topPadding: group.id == groups.first?.id ? 0 : Theme.Spacing.small
                        )
                        .gridCellColumns(2)
                    }

                    ForEach(group.details) { detail in
                        ContactDetailRow(detail: detail, affinity: group.affinity) { act(on: detail) }
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

/// The category a run of rows belongs to: which side of somebody's life these details are.
///
/// ### Why this is a heading and not a pill any more
/// It was `ContactAffinityChip` — a tinted capsule, in the affinity's own colour, floating above a
/// grid it was not part of. Three problems. It read at the same weight as the values under it, so a
/// section of six facts had two of the loudest things in it saying "Personal" and "Work". It was the
/// only pill in a pane that otherwise has none, and this app's restraint about tinted backgrounds is
/// most of why it looks calm. And because it sat outside the grid, it aligned with nothing.
///
/// A heading is what it always was. Small, uppercase, kerned — the same treatment every other
/// section header in the app uses — so the eye reads it as a divider rather than as a value. The
/// colour and the symbol stay, at that size, where they mark the category without competing with it.
private struct ContactAffinityHeading: View {
    let affinity: ContactAffinity

    /// Space above, so the heading can sit closer to its own rows than to the group before it —
    /// applied here rather than to the enclosing `GridRow`, which would stop being a row.
    var topPadding: CGFloat = 0

    init(_ affinity: ContactAffinity, topPadding: CGFloat = 0) {
        self.affinity = affinity
        self.topPadding = topPadding
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: affinity.symbolName)
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(affinity.color)
                .accessibilityHidden(true)

            Text(affinity.displayName.uppercased())
                .font(Theme.Text.sectionHeader)
                .foregroundStyle(Theme.Colors.secondaryText)
                .kerning(Theme.Text.Tracking.caps)

            Spacer(minLength: 0)
        }
        .padding(.top, topPadding)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(affinity.displayName) details")
    }
}

/// One line of a person's card: label, value, and what can be done with it.
///
/// The value is selectable so it can be copied by hand, and there is a Copy button so it does not
/// have to be — reading an address onto a form is the commonest thing anybody does here, and
/// selecting a wrapped three-line address with a trackpad is not a pleasure.
private struct ContactDetailRow: View {
    let detail: ContactDetail

    /// The heading this row sits under, so the label can decline to repeat it.
    let affinity: ContactAffinity

    let onUse: () -> Void

    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        GridRow {
            // ### Why the label is quiet and the kind is a glyph
            // The label used to be drawn in the affinity's colour, which meant the *field name* was
            // the most saturated thing in the section — six coloured labels beside six plain values,
            // colouring the part nobody is looking for. The category carries the colour now, once,
            // in its heading. Down here the glyph says which kind of thing this is and the words say
            // what it was called; both are secondary, because the value is the point.
            Label(
                detail.displayLabel(under: affinity),
                systemImage: detail.kind.symbolName
            )
            .font(Theme.Text.metadata)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.Colors.secondaryText)
            .lineLimit(1)
            .gridColumnAlignment(.leading)

            // The value and its actions, together. Beside the value rather than at the pane's
            // trailing edge: a wide profile would otherwise strand the buttons half a screen from
            // the thing they act on, which is both a longer mouse journey and a weaker claim about
            // what they do.
            //
            // Revealed on hover, because a row of small glyphs down the right of every value is
            // chrome the eye has to step over to read the numbers — which is what the section is
            // for. They stay in the layout while hidden, so nothing shifts when the pointer arrives,
            // and they are always present for VoiceOver and for the keyboard.
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                // A postal address is three lines and an email is one, and both have to sit in the
                // same column without the row above stepping sideways. `fixedSize` vertically means
                // the value wraps rather than truncating; the grid keeps the left edge whatever it
                // wraps to.
                Text(detail.displayValue)
                    .font(Theme.Text.rowSubtitle)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.small) {
                    Button(action: copy) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(Theme.Text.metadata)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                    .help(didCopy ? "Copied" : "Copy \(detail.kind.displayName.lowercased())")
                    .accessibilityLabel("Copy \(detail.kind.displayName.lowercased())")

                    Button(action: onUse) {
                        Image(systemName: useSymbol)
                            .font(Theme.Text.metadata)
                    }
                    .buttonStyle(.borderless)
                    .help(useDescription)
                    .accessibilityLabel(useDescription)
                }
                // Both fade together, and the confirmation stays up after the pointer leaves —
                // a tick that vanishes with the pointer is a tick nobody saw.
                .opacity(isHovering || didCopy ? 1 : 0)

                Spacer(minLength: 0)
            }
            .gridColumnAlignment(.leading)
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .calmAnimation(value: isHovering)
        .calmAnimation(value: didCopy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(affinity.displayName) \(detail.kind.displayName.lowercased()), "
                + "\(detail.displayLabel), \(detail.displayValue)"
        )
    }

    /// Copies the value the address book stores, not the one on screen.
    ///
    /// A phone number is displayed grouped — `+44 20 7946 0958` — and pasting that into a dialler is
    /// a coin toss. ``ContactDetail/value`` is the stored spelling, which is what dials and what
    /// matches, and is what somebody pasting into another app wants.
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detail.value, forType: .string)

        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            didCopy = false
        }
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
