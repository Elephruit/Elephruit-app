import ElephruitCore
import Foundation
import SwiftData

/// A directed, typed edge between two items.
///
/// An explicit entity rather than a bare many-to-many relationship, because a link
/// carries meaning of its own: how it was made, what it is called, and — crucially —
/// whether it currently points at anything.
///
/// ### Unresolved links
/// A `[[Some Note]]` whose target does not exist yet is a *valid* link with
/// ``ItemLink/target`` `nil` and ``ItemLink/unresolvedTitle`` set. It renders
/// differently, offers to create the missing item, and resolves automatically when an
/// item with that title appears. This is why the target relationship is optional beyond
/// CloudKit's requirement that it be so.
///
/// ### Two relationships to one type
/// ``ItemLink/source`` and ``ItemLink/target`` both point at ``Item``, each with its own
/// inverse. This shape is flagged as risk R3 in `docs/08-risks.md` and is verified by
/// `ItemLinkPersistenceTests`; the documented fallback, if SwiftData mishandles it, is
/// to drop the inverse on `target` and resolve backlinks by an indexed `targetID` fetch.
@Model
public final class ItemLink {
    public var id: UUID = UUID()

    /// ``LinkKind`` raw value.
    public var kindRaw: String = LinkKind.wiki.rawValue

    public var createdAt: Date = Date()

    /// Alternate label from `[[Target|display text]]`.
    public var displayText: String?

    /// The title written in the text when no item matches it. Mutually exclusive with a
    /// non-nil ``ItemLink/target``.
    public var unresolvedTitle: String?

    /// Matching form of ``ItemLink/unresolvedTitle``, so resolution is a cheap lookup
    /// rather than a fold-and-compare over every candidate.
    public var unresolvedMatchKey: String?

    // MARK: Relationships

    /// The item the link is written in. Inverse: ``Item/outgoingLinks``.
    public var source: Item?

    /// The item the link points at, or `nil` while unresolved.
    /// Inverse: ``Item/incomingLinks``.
    public var target: Item?

    public init(
        id: UUID = UUID(),
        kind: LinkKind = .wiki,
        source: Item? = nil,
        target: Item? = nil,
        displayText: String? = nil,
        unresolvedTitle: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.source = source
        self.target = target
        self.displayText = displayText
        self.createdAt = createdAt
        self.setUnresolvedTitle(unresolvedTitle)
    }
}

extension ItemLink {
    public var kind: LinkKind {
        get { LinkKind(rawValue: kindRaw) ?? .related }
        set { kindRaw = newValue.rawValue }
    }

    public var isResolved: Bool { target != nil }

    /// Sets the unresolved title and its match key together, so they cannot disagree.
    public func setUnresolvedTitle(_ title: String?) {
        guard let title, !title.isEmpty else {
            unresolvedTitle = nil
            unresolvedMatchKey = nil
            return
        }
        unresolvedTitle = title
        unresolvedMatchKey = TextNormalizer.foldedForMatching(title)
    }

    /// Points the link at a real item, clearing the unresolved state.
    public func resolve(to item: Item) {
        target = item
        unresolvedTitle = nil
        unresolvedMatchKey = nil
    }

    /// What to show for this link.
    public var label: String {
        if let displayText, !displayText.isEmpty { return displayText }
        if let target { return target.displayTitle }
        return unresolvedTitle ?? "Untitled"
    }

    /// The title this link is trying to reach, resolved or not — used when reconciling
    /// body text against existing links.
    public var effectiveTargetTitle: String? {
        target?.title ?? unresolvedTitle
    }
}
