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
    @State private var selectedPage: ContactEditorPage = .name

    init(person: Item, onSave: @escaping (ContactDetailsEdit) -> Void, onCancel: @escaping () -> Void) {
        self.person = person
        self.onSave = onSave
        self.onCancel = onCancel
        _edit = State(initialValue: ContactDetailsEdit(profile: person.personProfile))
    }

    var body: some View {
        HStack(spacing: 0) {
            editorSidebar
            Divider()

            VStack(spacing: 0) {
                pageHeader
                Divider()
                ZStack {
                    Theme.Colors.windowBackground
                    pageContent
                        .id(selectedPage)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                Divider()
                editorFooter
            }
        }
        .frame(width: 860, height: 620)
        .background(Theme.Colors.windowBackground)
        .accessibilityIdentifier(AccessibilityID.People.contactEditor)
    }

    private var editorSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.medium) {
                ZStack {
                    Circle().fill(Theme.Colors.selection.gradient)
                    Text(personInitials)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.Colors.onAccent)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(person.displayTitle)
                        .font(.system(.headline, weight: .semibold))
                        .lineLimit(1)
                    Text("Contact profile")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.top, Theme.Spacing.section)
            .padding(.bottom, Theme.Spacing.large)

            Text("DETAILS")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.bottom, Theme.Spacing.small)

            VStack(spacing: 4) {
                ForEach(ContactEditorPage.allCases) { page in
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { selectedPage = page }
                    } label: {
                        HStack(spacing: Theme.Spacing.small) {
                            Image(systemName: page.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(selectedPage == page ? page.tint : Theme.Colors.secondaryText)
                                .frame(width: 24, height: 24)
                                .background(
                                    page.tint.opacity(selectedPage == page ? 0.14 : 0),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                            Text(page.title)
                                .font(.system(.body, weight: selectedPage == page ? .semibold : .regular))
                                .foregroundStyle(Theme.Colors.primaryText)
                            Spacer()
                            if let count = pageCount(page), count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(selectedPage == page ? page.tint : Theme.Colors.secondaryText)
                                    .padding(.horizontal, 6)
                                    .frame(minHeight: 18)
                                    .background(page.tint.opacity(0.1), in: Capsule())
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.small)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selectedPage == page ? Theme.Colors.contentBackground : .clear)
                                .shadow(color: selectedPage == page ? .black.opacity(0.06) : .clear, radius: 5, y: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.medium)

            Spacer()

            if isLinked {
                HStack(alignment: .top, spacing: Theme.Spacing.small) {
                    Image(systemName: "checkmark.icloud.fill")
                        .foregroundStyle(Theme.Colors.selection)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Linked to Contacts")
                            .font(.system(.caption, weight: .semibold))
                        Text("Changes are confirmed before writing back.")
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Spacing.medium)
                .background(Theme.Colors.selection.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .padding(Theme.Spacing.medium)
            }
        }
        .frame(width: 218)
    }

    private var pageHeader: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: selectedPage.systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(selectedPage.tint)
                .frame(width: 42, height: 42)
                .background(selectedPage.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedPage.title)
                    .font(.system(.title2, weight: .semibold))
                Text(selectedPage.subtitle)
                    .font(Theme.Text.rowSubtitle)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.section)
        .frame(height: 84)
        .background(Theme.Colors.contentBackground)
    }

    @ViewBuilder
    private var pageContent: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.large) {
                switch selectedPage {
                case .name:
                    EditorPanel {
                        VStack(spacing: Theme.Spacing.large) {
                            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                                EditorField("Prefix", text: $edit.namePrefix)
                                EditorField("First name", text: $edit.givenName)
                                EditorField("Middle name", text: $edit.middleName)
                            }
                            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                                EditorField("Last name", text: $edit.familyName)
                                EditorField("Suffix", text: $edit.nameSuffix)
                                EditorField("Nickname", text: $edit.nickname)
                            }
                        }
                    }
                case .work:
                    EditorPanel {
                        VStack(spacing: Theme.Spacing.large) {
                            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                                EditorField("Role", text: $edit.roleTitle)
                                EditorField("Department", text: $edit.departmentName)
                            }
                            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                                EditorField("Organization", text: $edit.organizationName)
                                EditorField("Location", text: $edit.locationText)
                            }
                        }
                    }
                case .birthday:
                    EditorPanel {
                        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                            Toggle(isOn: $edit.hasBirthday) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Remember their birthday")
                                        .font(.system(.body, weight: .semibold))
                                    Text("Show it in Celebrations and upcoming reminders.")
                                        .font(Theme.Text.rowSubtitle)
                                        .foregroundStyle(Theme.Colors.secondaryText)
                                }
                            }
                            .toggleStyle(.switch)
                            if edit.hasBirthday {
                                Divider()
                                HStack(spacing: Theme.Spacing.section) {
                                    DatePicker("Birthday", selection: $edit.birthday, displayedComponents: .date)
                                    Toggle("Include birth year", isOn: $edit.birthdayHasYear)
                                        .toggleStyle(.switch)
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                case .email: contactPage(.email)
                case .phone: contactPage(.phone)
                case .address: contactPage(.address)
                case .website: contactPage(.website)
                }
            }
            .padding(Theme.Spacing.section)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func contactPage(_ kind: ContactDetailKind) -> some View {
        EditorPanel { ValueListSection(kind: kind, values: binding(for: kind)) }
    }

    private var personInitials: String {
        person.displayTitle.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private func pageCount(_ page: ContactEditorPage) -> Int? {
        switch page {
        case .name, .work: nil
        case .birthday: edit.hasBirthday ? 1 : nil
        case .email: edit.emails.count
        case .phone: edit.phones.count
        case .address: edit.addresses.count
        case .website: edit.websites.count
        }
    }

    private var editorFooter: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let saveFailure {
                Label(saveFailure.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.overdue)
            }

            HStack(spacing: Theme.Spacing.medium) {
                Text("Changes are saved to this profile first.")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Spacer()

                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Save Changes", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, Theme.Spacing.section)
        .frame(minHeight: 58)
        .background(Theme.Colors.contentBackground)
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

            // The person is shown under the item's title everywhere outside this sheet, so a name
            // edited here has to reach it or the header would still read the old one. Assembled from
            // the parts rather than typed as a line, which is the direction that does not guess.
            let assembled = cleaned.displayName
            try services.items.update(person) { subject in
                if !assembled.isEmpty { subject.title = assembled }
                subject.refreshSearchText()
            }

            services.refreshDerivedState()
            onSave(cleaned)
        } catch {
            saveFailure = error
        }
    }
}

private enum ContactEditorPage: String, CaseIterable, Identifiable {
    case name, work, birthday, email, phone, address, website

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var subtitle: String {
        switch self {
        case .name: "How this person appears throughout the app"
        case .work: "Their role, team, and organization"
        case .birthday: "A date worth remembering"
        case .email: "Where you can reach them by email"
        case .phone: "Numbers for calls and messages"
        case .address: "Places associated with this person"
        case .website: "Personal and professional links"
        }
    }

    var systemImage: String {
        switch self {
        case .name: "person.fill"
        case .work: "briefcase.fill"
        case .birthday: "birthday.cake.fill"
        case .email: "envelope.fill"
        case .phone: "phone.fill"
        case .address: "mappin.and.ellipse"
        case .website: "safari.fill"
        }
    }

    var tint: Color {
        switch self {
        case .name: Theme.Palette.blue.color
        case .work: Theme.Palette.indigo.color
        case .birthday: Theme.Palette.pink.color
        case .email: Theme.Palette.cyan.color
        case .phone: Theme.Palette.green.color
        case .address: Theme.Palette.orange.color
        case .website: Theme.Palette.purple.color
        }
    }
}

/// A quiet canvas for the selected task, rather than one card in a long stack.
private struct EditorPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
        .padding(Theme.Spacing.section)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.Colors.contentBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.Colors.separator.opacity(0.55))
        )
        .shadow(color: .black.opacity(0.04), radius: 16, y: 6)
    }
}

/// A field whose label stays above the value, so editing always begins at the leading edge.
private struct EditorField: View {
    let title: String
    @Binding var text: String
    let width: CGFloat?

    init(_ title: String, text: Binding<String>, width: CGFloat? = nil) {
        self.title = title
        _text = text
        self.width = width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(title)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            TextField("", text: $text)
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, Theme.Spacing.small)
                .frame(height: 32)
                .background(fieldBackground)
                .accessibilityLabel(title)
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .fill(Theme.Colors.windowBackground)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.Colors.separator.opacity(0.8))
            )
    }
}

/// One kind's list of labelled values, with the controls that make it a list rather than a display.
private struct ValueListSection: View {
    let kind: ContactDetailKind
    @Binding var values: [LabelledValue]

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            if values.isEmpty {
                VStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(kind.editorTint)
                        .frame(width: 54, height: 54)
                        .background(kind.editorTint.opacity(0.1), in: Circle())
                    VStack(spacing: 4) {
                        Text("No \(kind.displayName.lowercased()) added")
                            .font(.system(.body, weight: .semibold))
                        Text("Add one whenever it becomes useful.")
                            .font(Theme.Text.rowSubtitle)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.section)
            } else {
                ForEach(values.indices, id: \.self) { index in
                    HStack(alignment: .center, spacing: Theme.Spacing.medium) {
                        LabelField(label: $values[index].label, kind: kind)

                        TextField("", text: $values[index].value)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, Theme.Spacing.small)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                                    .fill(Theme.Colors.windowBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                                            .strokeBorder(Theme.Colors.separator.opacity(0.8))
                                    )
                            )
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(kind.displayName)

                        Button {
                            values.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this \(kind.displayName.lowercased())")
                        .accessibilityLabel("Remove this \(kind.displayName.lowercased())")
                    }

                    if index != values.indices.last { Divider() }
                }
            }

            Button {
                values.append(LabelledValue(label: kind.editorDefaultLabel, value: ""))
            } label: {
                Label("Add \(kind.displayName.lowercased())", systemImage: "plus.circle")
                    .font(.system(.body, weight: .semibold))
                    .padding(.horizontal, Theme.Spacing.medium)
                    .frame(height: 34)
                    .background(kind.editorTint.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(kind.editorTint)
            .frame(maxWidth: .infinity, alignment: values.isEmpty ? .center : .leading)
        }
        .animation(.easeOut(duration: 0.16), value: values.count)
    }
}

/// A label that can be picked from the common ones or typed outright.
private struct LabelField: View {
    @Binding var label: String
    let kind: ContactDetailKind

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            TextField("", text: $label)
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .padding(.leading, Theme.Spacing.small)
                .accessibilityLabel("Label")

            Menu {
                ForEach(kind.editorLabelOptions, id: \.self) { option in
                    Button(option) { label = option }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .help("Common labels")
            .accessibilityLabel("Choose a common label")
        }
        .frame(width: 146, height: 36, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Colors.windowBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Theme.Colors.separator.opacity(0.8))
                )
        )
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

    var givenName: String
    var middleName: String
    var familyName: String
    var namePrefix: String
    var nameSuffix: String
    var nickname: String

    var roleTitle: String
    var departmentName: String
    var organizationName: String
    var locationText: String

    var emails: [LabelledValue]
    var phones: [LabelledValue]
    var addresses: [LabelledValue]
    var websites: [LabelledValue]

    /// Whether a birthday is recorded at all, kept separately so the picker can hold a sensible date
    /// while the answer is still "none".
    var hasBirthday: Bool
    var birthday: Date
    var birthdayHasYear: Bool

    init(profile: PersonProfile?, calendar: Calendar = .current, today: Date = Date()) {
        givenName = profile?.givenName ?? ""
        middleName = profile?.middleName ?? ""
        familyName = profile?.familyName ?? ""
        namePrefix = profile?.namePrefix ?? ""
        nameSuffix = profile?.nameSuffix ?? ""
        nickname = profile?.nickname ?? ""

        roleTitle = profile?.roleTitle ?? ""
        departmentName = profile?.departmentName ?? ""
        organizationName = profile?.organizationName ?? ""
        locationText = profile?.locationText ?? ""

        emails = profile?.emails ?? []
        phones = profile?.phones ?? []
        addresses = profile?.addresses ?? []
        websites = profile?.websites ?? []

        hasBirthday = profile?.birthday != nil
        birthday = profile?.birthday ?? today
        birthdayHasYear = profile?.birthdayHasYear ?? false
        self.calendar = calendar
    }

    /// Held so the birthday can be read into parts without the view supplying one.
    private var calendar: Calendar

    /// The birthday as the rest of the app models it: day and month always, year only when known.
    var partialBirthday: PartialDate? {
        guard hasBirthday else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: birthday)
        guard let month = parts.month, let day = parts.day else { return nil }
        return PartialDate(year: birthdayHasYear ? parts.year : nil, month: month, day: day)
    }

    /// The name as one line, for anywhere that needs to show it whole.
    var displayName: String {
        [namePrefix, givenName, middleName, familyName, nameSuffix]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The edit with blank rows and surrounding whitespace removed.
    ///
    /// A value of nothing is not a value; a label of nothing is a value the card cannot introduce, so
    /// it falls back to the kind's usual label rather than rendering as a gap.
    func cleaned() -> ContactDetailsEdit {
        var result = self
        result.givenName = givenName.trimmed()
        result.middleName = middleName.trimmed()
        result.familyName = familyName.trimmed()
        result.namePrefix = namePrefix.trimmed()
        result.nameSuffix = nameSuffix.trimmed()
        result.nickname = nickname.trimmed()
        result.roleTitle = roleTitle.trimmed()
        result.departmentName = departmentName.trimmed()
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
            return LabelledValue(label: label.isEmpty ? kind.editorDefaultLabel : label, value: trimmed)
        }
    }

    /// Writes the edit onto a profile. Empty identity fields become `nil` rather than `""`, which is
    /// what the rest of the app tests for when deciding whether a line has anything to say.
    func apply(to profile: PersonProfile) {
        profile.givenName = givenName
        profile.familyName = familyName
        profile.middleName = middleName.isEmpty ? nil : middleName
        profile.namePrefix = namePrefix.isEmpty ? nil : namePrefix
        profile.nameSuffix = nameSuffix.isEmpty ? nil : nameSuffix
        profile.nickname = nickname.isEmpty ? nil : nickname

        profile.roleTitle = roleTitle.isEmpty ? nil : roleTitle
        profile.departmentName = departmentName.isEmpty ? nil : departmentName
        profile.organizationName = organizationName.isEmpty ? nil : organizationName
        profile.locationText = locationText.isEmpty ? nil : locationText

        profile.emails = emails
        profile.phones = phones
        profile.addresses = addresses
        profile.websites = websites

        profile.birthday = hasBirthday ? birthday : nil
        profile.birthdayHasYear = hasBirthday && birthdayHasYear
    }
}

private extension String {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension ContactDetailKind {
    var editorTint: Color {
        switch self {
        case .email: Theme.Palette.blue.color
        case .phone: Theme.Palette.green.color
        case .address: Theme.Palette.orange.color
        case .website: Theme.Palette.purple.color
        }
    }

    /// The label a newly added row starts with.
    var editorDefaultLabel: String {
        switch self {
        case .email, .phone: "personal"
        case .address: "home"
        case .website: "homepage"
        }
    }

    /// Offered in the menu. Not a closed set — the field beside it takes anything.
    var editorLabelOptions: [String] {
        switch self {
        case .email, .phone: ["personal", "work"]
        case .address: ["home", "work", "other"]
        case .website: ["homepage", "work", "blog", "other"]
        }
    }
}
