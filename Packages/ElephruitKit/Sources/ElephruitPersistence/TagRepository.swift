import ElephruitCore
import ElephruitModel
import Foundation
import SwiftData

/// Reading and writing tags.
///
/// Tag identity is the slug, and slug uniqueness is enforced here rather than by a store
/// constraint — CloudKit mirroring forbids unique attributes. ``TagRepository/ensureTags(named:)``
/// is therefore the *only* sanctioned way to obtain a tag, so two code paths cannot create
/// two `work` tags.
@MainActor
public protocol TagRepository: AnyObject {
    func allTags() throws(AppError) -> [Tag]
    func tag(slug: String) throws(AppError) -> Tag?

    /// Finds or creates tags for the given names, creating hierarchy ancestors as needed.
    func ensureTags(named names: [String]) throws(AppError) -> [Tag]

    func rename(_ tag: Tag, to newName: String) throws(AppError)
    func setColor(_ tag: Tag, colorName: String?) throws(AppError)
    func delete(_ tag: Tag) throws(AppError)

    /// Removes implicit ancestor tags that no longer have descendants or items.
    func pruneOrphanedImplicitTags() throws(AppError)
}

@MainActor
public final class SwiftDataTagRepository: TagRepository {
    private let context: ModelContext
    private let dateProvider: any DateProvider

    public init(context: ModelContext, dateProvider: any DateProvider) {
        self.context = context
        self.dateProvider = dateProvider
    }

    public func allTags() throws(AppError) -> [Tag] {
        let descriptor = FetchDescriptor<Tag>(sortBy: [SortDescriptor(\.slug)])
        do {
            return try context.fetch(descriptor)
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    public func tag(slug: String) throws(AppError) -> Tag? {
        var descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.slug == slug })
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            throw .storeUnavailable(underlying: error.localizedDescription)
        }
    }

    /// Resolves names to tags, creating what does not exist.
    ///
    /// `"work/clients/acme"` creates `work` and `work/clients` as *implicit* tags if they
    /// are absent, so the hierarchy is navigable without asking the user to declare each
    /// level. Only the leaf is returned — the ancestors are structure, not labels the item
    /// carries.
    public func ensureTags(named names: [String]) throws(AppError) -> [Tag] {
        var resolved: [Tag] = []
        var seenSlugs = Set<String>()

        for name in names {
            let slug = TextNormalizer.slug(name)
            guard TextNormalizer.isValidSlug(slug), seenSlugs.insert(slug).inserted else { continue }

            let components = TextNormalizer.slugComponents(slug)
            var ancestor: Tag?

            // Walk the path, creating each level that is missing.
            for depth in 1...max(1, components.count) {
                let partialSlug = components.prefix(depth).joined(separator: "/")
                let isLeaf = depth == components.count

                let existing = try tag(slug: partialSlug)
                let tag: Tag

                if let existing {
                    tag = existing
                    // A tag the user now names explicitly is no longer just structure.
                    if isLeaf, tag.isImplicit { tag.isImplicit = false }
                } else {
                    tag = Tag(
                        name: isLeaf ? name : partialSlug,
                        isImplicit: !isLeaf,
                        createdAt: dateProvider.now
                    )
                    tag.slug = partialSlug
                    tag.parent = ancestor
                    context.insert(tag)
                }

                ancestor = tag
                if isLeaf { resolved.append(tag) }
            }
        }

        try save()
        return resolved
    }

    public func rename(_ tag: Tag, to newName: String) throws(AppError) {
        let newSlug = TextNormalizer.slug(newName)

        guard TextNormalizer.isValidSlug(newSlug) else {
            throw .validation(ValidationFailure(reason: .emptyTagName, field: "name"))
        }

        // Renaming onto an existing slug would create the duplicate the whole design is
        // built to prevent. Merging is a deliberate action, not a side effect of a rename.
        if newSlug != tag.slug, try self.tag(slug: newSlug) != nil {
            throw .validation(ValidationFailure(reason: .emptyTagName, field: "name"))
        }

        let oldSlug = tag.slug
        try tag.rename(to: newName)

        // Descendants carry the path in their slug, so they must move with it.
        try reslugDescendants(of: tag, oldPrefix: oldSlug, newPrefix: newSlug)

        // Items' searchText contains tag slugs.
        try refreshSearchText(forItemsTaggedBy: tag)

        try save()
    }

    private func reslugDescendants(of tag: Tag, oldPrefix: String, newPrefix: String) throws(AppError) {
        for child in (tag.children ?? []) {
            let suffix = child.slug.dropFirst(oldPrefix.count)
            child.slug = newPrefix + suffix
            try reslugDescendants(of: child, oldPrefix: oldPrefix + suffix, newPrefix: child.slug)
            try refreshSearchText(forItemsTaggedBy: child)
        }
    }

    private func refreshSearchText(forItemsTaggedBy tag: Tag) throws(AppError) {
        for item in (tag.items ?? []) {
            item.refreshSearchText()
        }
    }

    public func setColor(_ tag: Tag, colorName: String?) throws(AppError) {
        tag.colorName = colorName
        try save()
    }

    /// Removes a tag. Items lose the label; descendants are orphaned rather than destroyed.
    public func delete(_ tag: Tag) throws(AppError) {
        let affectedItems = tag.items

        for child in (tag.children ?? []) {
            child.parent = tag.parent
        }

        context.delete(tag)

        for item in (affectedItems ?? []) {
            item.refreshSearchText()
        }

        try save()
    }

    /// Cleans up hierarchy levels that exist only because something below them did.
    public func pruneOrphanedImplicitTags() throws(AppError) {
        let candidates = try allTags().filter(\.isImplicit)
        var removed = 0

        for tag in candidates where (tag.children ?? []).isEmpty && (tag.items ?? []).isEmpty {
            context.delete(tag)
            removed += 1
        }

        if removed > 0 {
            try save()
            Diagnostics.persistence.debug("Pruned \(removed, privacy: .public) implicit tag(s)")
        }
    }

    private func save() throws(AppError) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw .writeFailed(path: "store", reason: error.localizedDescription)
        }
    }
}
