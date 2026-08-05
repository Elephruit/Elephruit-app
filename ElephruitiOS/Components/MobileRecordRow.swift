import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import SwiftUI

/// One subject in the Records list: their face, their name, and where they are from.
///
/// ### Why this is not `MobileItemRow`
/// `MobileItemRow` is the one way an *item* is drawn — a task, a note, a meeting — and it stays
/// that. This is the one way a **record** is drawn, and the difference is not decoration. An item
/// row answers *what is this and when is it due*; the leading glyph is a category mark and the
/// trailing edge carries a date. A record row answers *who is this*, and the answer to that is a
/// face. Every address book on the platform draws it this way, and it is why the leading slot is
/// large enough to be a picture rather than a symbol.
///
/// The anatomy is still the anatomy: a leading control, a title, one line of context, a mark on the
/// trailing edge. Only what goes in the leading slot changed, which is the kind difference
/// `MobileItemRow`'s own rule permits.
///
/// ### Why it takes an entry rather than the record
/// Because a row body must not read the store. `PersonListEntry` is everything this draws, computed
/// once when the list is built; reaching for `item.personProfile?.organizationName` here would fault
/// the profile relationship on every row that scrolled past, which is the cost that put the tint and
/// the star on the entry in the first place. The contact identifier is on the entry for exactly the
/// same reason — it is a pointer to a photograph, and following it is this row's job, not the
/// list's.
struct MobileRecordRow: View {
    @Environment(\.services) private var services

    let entry: PersonListEntry

    /// The face, once the address book has answered.
    ///
    /// A `@State` per row rather than a shared observable read: only the row that asked redraws when
    /// its own photograph lands. See `ContactPhotoStore` for the version of this that invalidated
    /// every visible row at once.
    @State private var photo: Data?

    /// Large enough to be a photograph rather than a symbol, and the reason the row is taller than
    /// an item row.
    private static let faceDiameter = Theme.Size.iconTileLarge

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            leading

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(entry.displayName)
                    .font(Theme.Text.rowTitle)
                    .foregroundStyle(Theme.Colors.primaryText)
                    .lineLimit(1)

                if let context {
                    Text(context)
                        .font(Theme.Text.rowSubtitle)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Groups before the star: the star is one bit about this person and the dots are about
            // their place among everybody else, so the dots sit inboard where the eye scans names
            // and the star stays pinned to the edge where it always was.
            GroupDots(groups: entry.groups)

            if entry.isFavorite {
                Image(systemName: "star.fill")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.favorite)
                    .accessibilityHidden(true)
            }
        }
        // The face and nothing more. The breathing room is the list's row insets, which is the only
        // place it can live without being counted twice — a minimum height that already included it
        // put a 44-point avatar in a 96-point row.
        .frame(minHeight: Self.faceDiameter)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // Keyed on the identifier, so a recycled row re-asks for the person it is now showing rather
        // than keeping the last one's face. Cache hits return without touching Contacts.
        .task(id: entry.contactIdentifier) {
            photo = await services?.contacts.photo(forContactIdentifier: entry.contactIdentifier)
        }
    }

    /// A photograph, a monogram, or the record type's own glyph.
    ///
    /// A monogram is the right picture of a human being and the wrong picture of a Toyota: "TC" in a
    /// circle says *somebody called T— C—*. So initials are for the record types that have them —
    /// people and pets, both of which are somebody with a name — and everything else keeps the
    /// symbol that says what it is.
    @ViewBuilder
    private var leading: some View {
        switch entry.recordType {
        case .person, .pet:
            Avatar(
                name: entry.displayName,
                diameter: Self.faceDiameter,
                tint: Theme.Palette.color(named: entry.colorName),
                // Read synchronously first so an already-known face is on screen in the same frame
                // the row is; `photo` carries the one that has only just arrived.
                photo: photo ?? services?.contacts.cachedPhoto(forContactIdentifier: entry.contactIdentifier)
            )
        case .vehicle, .organization, .other:
            IconTile(
                systemImage: entry.recordType.symbolName,
                tint: Theme.Palette.color(named: entry.colorName),
                size: .large
            )
        }
    }

    /// Where they work, when that is known and is not already the name on the row.
    ///
    /// The second check matters for organizations, which are their own employer: "Northwind Studio"
    /// written twice, once large and once small, is the list stuttering.
    private var context: String? {
        guard let organization = entry.organizationName?.trimmingCharacters(in: .whitespaces),
              !organization.isEmpty,
              organization.caseInsensitiveCompare(entry.displayName) != .orderedSame
        else { return nil }
        return organization
    }

    /// The star is drawn but hidden from VoiceOver as a glyph, so it is said here instead — a
    /// favorite that is only a shape is a favorite a screen-reader user cannot know about.
    private var accessibilityLabel: String {
        [
            entry.displayName,
            context,
            // Every group, not only the drawn ones: the dots are capped because the row is narrow,
            // and this reader is not. A dot left to announce itself would say "circle".
            GroupDots.accessibilityText(for: entry.groups),
            entry.isFavorite ? "Favorite" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}
