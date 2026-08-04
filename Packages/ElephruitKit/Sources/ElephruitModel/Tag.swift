import ElephruitCore
import Foundation
import SwiftData

/// A label, optionally hierarchical.
///
/// Identity is the ``Tag/slug`` — a normalised, case-folded form — so `#Work` and
/// `#work` are the same tag and `#Läunch` matches `#launch`. Uniqueness of the slug is
/// enforced by `TagRepository`, not by a store constraint, because CloudKit mirroring
/// forbids unique attributes.
@Model
public final class Tag {
    public var id: UUID = UUID()

    /// As the user typed it, for display.
    public var name: String = ""

    /// Normalised form, for matching and for `tag:` search tokens. See
    /// ``TextNormalizer/slug(_:)``.
    public var slug: String = ""

    /// Semantic palette key. `nil` renders in the neutral tag style.
    public var colorName: String?

    public var createdAt: Date = Date()

    /// Non-nil means the tag was created implicitly as an ancestor of another tag
    /// (`work` when the user typed `work/clients`), and may be pruned when its last
    /// descendant goes.
    public var isImplicit: Bool = false

    // MARK: Relationships

    /// Parent in the hierarchy — `work` for `work/clients`.
    public var parent: Tag?

    /// Nullify rather than cascade: deleting `work` should orphan `work/clients`, not
    /// destroy it along with every item's tagging.
    @Relationship(deleteRule: .nullify, inverse: \Tag.parent)
    public var children: [Tag] = []

    /// Many-to-many. The inverse is declared on ``Item/tags``.
    public var items: [Item] = []

    /// Many-to-many with tracked time. The inverse is declared on ``TimeEntry/tags``.
    ///
    /// Every relationship carries an inverse because CloudKit mirroring requires one, and
    /// the decision of record is that deferring sync must not make adopting it harder later.
    /// This pair was the one omission — same file, three lines from the rule.
    public var timeEntries: [TimeEntry] = []

    public init(
        id: UUID = UUID(),
        name: String,
        colorName: String? = nil,
        isImplicit: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.slug = TextNormalizer.slug(name)
        self.colorName = colorName
        self.isImplicit = isImplicit
        self.createdAt = createdAt
    }
}

extension Tag {
    /// Renames the tag, keeping ``Tag/slug`` in step. The only sanctioned way to change
    /// a name, so the two can never drift.
    public func rename(to newName: String) throws(AppError) {
        let newSlug = TextNormalizer.slug(newName)
        guard TextNormalizer.isValidSlug(newSlug) else {
            throw .validation(ValidationFailure(reason: .emptyTagName, field: "name"))
        }
        name = newName
        slug = newSlug
    }

    /// The last path component — `clients` for `work/clients`.
    public var leafName: String {
        TextNormalizer.slugComponents(slug).last ?? slug
    }

    /// Depth in the hierarchy; a top-level tag is 0.
    public var depth: Int {
        max(0, TextNormalizer.slugComponents(slug).count - 1)
    }

    /// How many non-trashed items carry this tag.
    public var activeItemCount: Int {
        items.count { $0.deletedAt == nil }
    }

    /// Display name for the sidebar, which shows hierarchy through indentation rather
    /// than by repeating the whole path.
    public var displayName: String {
        name.isEmpty ? slug : name
    }
}
