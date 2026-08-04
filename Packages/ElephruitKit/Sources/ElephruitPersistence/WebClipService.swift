import ElephruitCore
import ElephruitModel
import Foundation

/// Turns a browser-produced clip into an ordinary Elephruit item and managed attachments.
///
/// The service deliberately has no Safari dependency. A future share extension or Chromium bridge
/// can submit the same value and receive exactly the same item, provenance, filing, and indexing.
@MainActor
public struct WebClipService {
    public static let maximumTextLength = 8_000_000
    public static let maximumScreenshotBytes = 24_000_000

    private let items: any ItemRepository
    private let attachments: AttachmentStore

    public init(items: any ItemRepository, attachments: AttachmentStore) {
        self.items = items
        self.attachments = attachments
    }

    @discardableResult
    public func save(_ clip: WebClip) throws(AppError) -> Item {
        guard clip.version == WebClip.currentVersion else {
            throw .importFailed(format: "web clip", reason: "This clip was created by an unsupported version.")
        }
        guard clip.sourceURL.isWebURL else {
            throw .importFailed(format: "web clip", reason: "Only HTTP and HTTPS pages can be clipped.")
        }
        guard clip.contentMarkdown.count <= Self.maximumTextLength,
              (clip.contentHTML?.count ?? 0) <= Self.maximumTextLength else {
            throw .importFailed(format: "web clip", reason: "The page is too large to clip safely.")
        }
        guard (clip.screenshotData?.count ?? 0) <= Self.maximumScreenshotBytes else {
            throw .importFailed(format: "web clip", reason: "The screenshot is too large to save.")
        }

        let sourceURL = clip.preferredSourceURL
        let item: Item
        if let existing = try items.item(id: clip.id) {
            guard existing.source.kind == .webClip else {
                throw .importFailed(format: "web clip", reason: "The clip identifier is already in use.")
            }
            item = existing
        } else {
            let kind: ItemKind = clip.mode == .bookmark ? .bookmark : .note
            item = try items.create(
                ItemDraft(
                    id: clip.id,
                    kind: kind,
                    title: normalizedTitle(clip.title, sourceURL: sourceURL),
                    body: noteBody(for: clip, sourceURL: sourceURL),
                    tagSlugs: normalizedTags(clip.tagSlugs),
                    source: ItemSource(kind: .webClip, url: sourceURL, identifier: clip.mode.rawValue),
                    url: sourceURL
                )
            )

            if let project = try resolveContainer(named: clip.projectHint) {
                try items.fileItem(item, under: project)
            }
        }

        if let html = clip.contentHTML?.trimmingCharacters(in: .whitespacesAndNewlines),
           !html.isEmpty,
           !item.attachments.contains(where: { $0.typeIdentifier == "public.html" }) {
            _ = try attachments.attach(
                data: Data(html.utf8),
                filename: "\(filenameStem(for: item.title)).html",
                typeIdentifier: "public.html",
                to: item
            )
        }

        if let screenshot = clip.screenshotData,
           !screenshot.isEmpty,
           !item.attachments.contains(where: { $0.typeIdentifier == "public.png" }) {
            _ = try attachments.attach(
                data: screenshot,
                filename: "\(filenameStem(for: item.title))-screenshot.png",
                typeIdentifier: "public.png",
                to: item
            )
        }

        return item
    }

    private func noteBody(for clip: WebClip, sourceURL: URL) -> String {
        var sections: [String] = []
        let comment = clip.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty { sections.append(comment) }

        var source = "[Open original](\(sourceURL.absoluteString))"
        let byline = [clip.siteName, clip.author]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        if !byline.isEmpty { source += "  \n\(byline)" }
        sections.append(source)

        let content = clip.contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            sections.append(content)
        } else if let excerpt = clip.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines), !excerpt.isEmpty {
            sections.append(excerpt)
        }

        return sections.joined(separator: "\n\n---\n\n")
    }

    private func normalizedTitle(_ proposed: String, sourceURL: URL) -> String {
        let title = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return String(title.prefix(500)) }
        return sourceURL.host(percentEncoded: false) ?? "Web clip"
    }

    private func normalizedTags(_ proposed: [String]) -> [String] {
        var seen: Set<String> = []
        return proposed.compactMap { value in
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .lowercased()
            guard !tag.isEmpty, seen.insert(tag).inserted else { return nil }
            return tag
        }
    }

    private func resolveContainer(named hint: String?) throws(AppError) -> Item? {
        guard let hint else { return nil }
        let folded = TextNormalizer.foldedForMatching(hint)
        guard !folded.isEmpty else { return nil }

        var query = ItemQuery()
        query.kinds = [.project, .area, .goal]
        let candidates = try items.items(matching: query)
        return candidates.first { TextNormalizer.foldedForMatching($0.title) == folded }
            ?? candidates.first { TextNormalizer.foldedForMatching($0.title).hasPrefix(folded) }
    }

    private func filenameStem(for title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let pieces = title.components(separatedBy: illegal).filter { !$0.isEmpty }
        let joined = pieces.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return String((joined.isEmpty ? "Web clip" : joined).prefix(100))
    }
}
