import ElephruitCore
import ElephruitDesign
import ElephruitIntegrations
import ElephruitModel
import SwiftUI

/// Asks whether an edit should also be written into the system address book.
///
/// ### Why this sheet exists at all
/// The app held read-only access to Contacts for its whole life, and the reasoning was that the
/// strongest reading of "system contacts change only with explicit user intent" is not a dialogue but
/// not having the capability. The cost of that was a linked person whose number could not be
/// corrected anywhere: fixing it locally meant the next refresh overwriting the fix without a word.
///
/// So the capability now exists and the intent is explicit rather than absent. The rules it is held
/// to are the ones the read-only posture was protecting:
///
/// - **Nothing is written until this sheet is answered.** The local record has already been saved by
///   the time it opens, so declining is a complete and coherent outcome rather than a lost edit.
/// - **Every changed line is shown, before and after.** A confirmation that says "save changes?"
///   without saying which is a click-through, and a click-through is not intent.
/// - **Nothing is written that the user did not touch.** The write carries the four editable fields
///   and no others, so a birthday or a photograph cannot be collateral damage.
/// - **A refusal is reported in words.** A read-only account or a deleted record ends with the user
///   knowing their address book still says the old thing.
struct ContactWriteBackSheet: View {
    @Environment(\.services) private var services

    let person: Item
    let edit: ContactDetailsEdit
    let onFinish: () -> Void

    @State private var outcome: ContactWriteOutcome?
    @State private var isWriting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Update your address book?")
                .font(Theme.Text.title)

            Text(
                "\(person.displayTitle) is linked to a contact. Elephruit has saved your changes; "
                    + "your address book still has the old values."
            )
            .font(Theme.Text.rowSubtitle)
            .foregroundStyle(Theme.Colors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if let outcome, outcome != .written {
                Label(outcome.explanation ?? "The change was not written.", systemImage: "exclamationmark.triangle")
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.overdue)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                changeList
            }

            if !edit.addresses.isEmpty {
                // Said plainly rather than discovered later. See `ContactsProviding.write(_:)` for
                // why an address cannot make the trip back.
                Label(
                    "Addresses stay in Elephruit only. Your address book stores them as separate "
                        + "fields, and Elephruit keeps them as one line — writing that back would "
                        + "scramble them.",
                    systemImage: "info.circle"
                )
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()

                Button(outcome == nil ? "Keep in Elephruit Only" : "Done", role: .cancel, action: onFinish)
                    .keyboardShortcut(.cancelAction)

                if outcome == nil {
                    Button("Update Address Book", action: write)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(isWriting)
                }
            }
        }
        .padding(Theme.Spacing.large)
        .frame(minWidth: 460)
        .accessibilityIdentifier(AccessibilityID.People.contactWriteBackSheet)
    }

    /// The four writable lists, each shown only when it has something in it.
    @ViewBuilder
    private var changeList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            row("Role", edit.roleTitle)
            row("Organisation", edit.organizationName)

            ForEach(writableGroups, id: \.title) { group in
                ForEach(Array(group.values.enumerated()), id: \.offset) { _, value in
                    row("\(group.title) (\(value.label))", value.value)
                }
            }
        }
        .padding(Theme.Spacing.small)
        .background(Theme.Colors.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
    }

    private var writableGroups: [(title: String, values: [LabelledValue])] {
        [
            ("Email", edit.emails),
            ("Phone", edit.phones),
            ("Website", edit.websites),
        ].filter { !$0.values.isEmpty }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(label)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .frame(width: 140, alignment: .leading)

                Text(value)
                    .font(Theme.Text.rowSubtitle)
                    .textSelection(.enabled)

                Spacer(minLength: 0)
            }
        }
    }

    private func write() {
        guard let services, let identifier = person.personProfile?.contactsIdentifier else { return }

        isWriting = true

        Task {
            let result = await services.contacts.write(
                ContactWrite(
                    identifier: identifier,
                    jobTitle: edit.roleTitle,
                    organizationName: edit.organizationName,
                    emailAddresses: edit.emails.map { ContactLabelledValue(label: $0.label, value: $0.value) },
                    phoneNumbers: edit.phones.map { ContactLabelledValue(label: $0.label, value: $0.value) },
                    urlAddresses: edit.websites.map { ContactLabelledValue(label: $0.label, value: $0.value) }
                )
            )

            isWriting = false

            // A clean write closes the sheet: the user asked for one thing, it happened, and an
            // acknowledgement they have to dismiss is a second click for no information. Anything
            // else stays open, because it is news.
            if result == .written {
                onFinish()
            } else {
                outcome = result
            }
        }
    }
}
