import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

/// Editing somebody's addresses, numbers, sites, and where they work.
///
/// ### Why a sheet and not the usual inline edit
/// The rest of the portrait edits in place because each card holds one value that changes on its own
/// — a name, a note, a fact. Contact details are four lists whose rows can be added, relabelled,
/// reordered, and removed, and doing that inline would mean a delete control beside every value on a
/// page whose main job is to be *read*. The sheet also gives the write-back to the address book a
/// place to be decided once, rather than after every keystroke.
///
/// ### Labels are free text, deliberately
/// Contacts lets somebody label a number "the shop", and re-labelling that to "Other" on a round trip
/// through Elephruit would be the app quietly losing information it was only asked to display. The
/// common labels are offered as a menu; anything can be typed.
struct EditContactDetailsSheet: View {
    @Environment(\.services) private var services

    let person: Item

    /// Called once the edit is saved locally, with the values as they now stand, so the caller can
    /// decide what — if anything — to do about the address book.
    let onSave: (ContactDetailsEdit) -> Void
    let onCancel: () -> Void

    @State private var edit: ContactDetailsEdit
    @State private var saveFailure: AppError?

    init(person: Item, onSave: @escaping (ContactDetailsEdit) -> Void, onCancel: @escaping () -> Void) {
        self.person = person
        self.onSave = onSave
        self.onCancel = onCancel
        _edit = State(initialValue: ContactDetailsEdit(profile: person.personProfile))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Edit \(person.displayTitle)")
                .font(Theme.Text.title)

            Form {
                Section("Identity") {
                    TextField("Role", text: $edit.roleTitle)
                    TextField("Organisation", text: $edit.organizationName)
                    TextField("Location", text: $edit.locationText)
                }

                ForEach(ContactDetailKind.allCases, id: \.rawValue) { kind in
                    ValueListSection(kind: kind, values: binding(for: kind))
                }
            }
            .formStyle(.grouped)

            if let saveFailure {
                Label(saveFailure.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.overdue)
            }

            HStack {
                if isLinked {
                    Label(
                        "Linked to your address book — you will be asked before anything is written there.",
                        systemImage: "person.crop.rectangle.stack"
                    )
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                }

                Spacer()

                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(minWidth: 520, minHeight: 480)
        .accessibilityIdentifier(AccessibilityID.People.contactEditor)
    }

    private var isLinked: Bool {
        person.personProfile?.contactsIdentifier != nil
    }

    private func binding(for kind: ContactDetailKind) -> Binding<[LabelledValue]> {
        switch kind {
        case .email: $edit.emails
        case .phone: $edit.phones
        case .address: $edit.addresses
        case .website: $edit.websites
        }
    }

    /// Writes the edit to the person's own record.
    ///
    /// Blank rows are dropped rather than stored: an empty row is how somebody abandons an addition
    /// they started, and keeping it would put a labelled nothing on the card.
    private func save() {
        guard let services else { return }

        let cleaned = edit.cleaned()

        do {
            try services.persons.updateProfile(of: person) { profile in
                cleaned.apply(to: profile)
            }
            // Emails and the organisation feed the item's search projection, so a person renamed
            // here stays findable by the new value rather than the old one.
            try services.items.update(person) { $0.refreshSearchText() }
            services.refreshDerivedState()
            onSave(cleaned)
        } catch {
            saveFailure = error
        }
    }
}

/// One kind's list of labelled values, with the controls that make it a list rather than a display.
private struct ValueListSection: View {
    let kind: ContactDetailKind
    @Binding var values: [LabelledValue]

    var body: some View {
        Section(kind.displayName) {
            ForEach($values, id: \.self) { $value in
                HStack(spacing: Theme.Spacing.small) {
                    LabelField(label: $value.label, kind: kind)

                    TextField(kind.valuePrompt, text: $value.value)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        remove(value)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this \(kind.displayName.lowercased())")
                    .accessibilityLabel("Remove this \(kind.displayName.lowercased())")
                }
            }

            Button {
                values.append(LabelledValue(label: kind.defaultLabel, value: ""))
            } label: {
                Label("Add \(kind.displayName.lowercased())", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func remove(_ value: LabelledValue) {
        guard let index = values.firstIndex(of: value) else { return }
        values.remove(at: index)
    }
}

/// A label that can be picked from the common ones or typed outright.
private struct LabelField: View {
    @Binding var label: String
    let kind: ContactDetailKind

    var body: some View {
        HStack(spacing: 2) {
            TextField("Label", text: $label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)

            Menu {
                ForEach(kind.commonLabels, id: \.self) { option in
                    Button(option) { label = option }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 16)
            .help("Common labels")
            .accessibilityLabel("Choose a common label")
        }
    }
}

/// A pending change to somebody's contact details.
///
/// A value type rather than a set of mutations against the model, because the same edit has to be
/// applied in two places — the person's own record, and, when they are linked and the user says so,
/// the address book. Those cannot be the same write, and they must be the same *values*.
struct ContactDetailsEdit: Equatable, Identifiable {
    /// Identity for `sheet(item:)` only. A new edit is a new sheet; two edits with the same values
    /// are still two separate decisions about the address book.
    let id = UUID()

    var roleTitle: String
    var organizationName: String
    var locationText: String

    var emails: [LabelledValue]
    var phones: [LabelledValue]
    var addresses: [LabelledValue]
    var websites: [LabelledValue]

    init(profile: PersonProfile?) {
        roleTitle = profile?.roleTitle ?? ""
        organizationName = profile?.organizationName ?? ""
        locationText = profile?.locationText ?? ""
        emails = profile?.emails ?? []
        phones = profile?.phones ?? []
        addresses = profile?.addresses ?? []
        websites = profile?.websites ?? []
    }

    /// The edit with blank rows and surrounding whitespace removed.
    ///
    /// A value of nothing is not a value; a label of nothing is a value the card cannot introduce, so
    /// it falls back to the kind's usual label rather than rendering as a gap.
    func cleaned() -> ContactDetailsEdit {
        var result = self
        result.roleTitle = roleTitle.trimmed()
        result.organizationName = organizationName.trimmed()
        result.locationText = locationText.trimmed()
        result.emails = Self.clean(emails, kind: .email)
        result.phones = Self.clean(phones, kind: .phone)
        result.addresses = Self.clean(addresses, kind: .address)
        result.websites = Self.clean(websites, kind: .website)
        return result
    }

    private static func clean(_ values: [LabelledValue], kind: ContactDetailKind) -> [LabelledValue] {
        values.compactMap { value in
            let trimmed = value.value.trimmed()
            guard !trimmed.isEmpty else { return nil }
            let label = value.label.trimmed()
            return LabelledValue(label: label.isEmpty ? kind.defaultLabel : label, value: trimmed)
        }
    }

    /// Writes the edit onto a profile. Empty identity fields become `nil` rather than `""`, which is
    /// what the rest of the app tests for when deciding whether a line has anything to say.
    func apply(to profile: PersonProfile) {
        profile.roleTitle = roleTitle.isEmpty ? nil : roleTitle
        profile.organizationName = organizationName.isEmpty ? nil : organizationName
        profile.locationText = locationText.isEmpty ? nil : locationText
        profile.emails = emails
        profile.phones = phones
        profile.addresses = addresses
        profile.websites = websites
    }
}

private extension String {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension ContactDetailKind {
    /// What an empty field asks for. Specific enough to imply the format without stating a rule.
    var valuePrompt: String {
        switch self {
        case .email: "name@example.com"
        case .phone: "+1 512 555 0192"
        case .address: "12 Rosewood Lane, Austin"
        case .website: "example.com"
        }
    }

    /// The label a newly added row starts with.
    var defaultLabel: String {
        switch self {
        case .email: "home"
        case .phone: "mobile"
        case .address: "home"
        case .website: "homepage"
        }
    }

    /// Offered in the menu. Not a closed set — the field beside it takes anything.
    var commonLabels: [String] {
        switch self {
        case .email: ["home", "work", "school", "other"]
        case .phone: ["mobile", "home", "work", "main", "other"]
        case .address: ["home", "work", "other"]
        case .website: ["homepage", "work", "blog", "other"]
        }
    }
}
