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
    public static let maximumImageBytes = 24_000_000

    private let items: any ItemRepository
    private let attachments: AttachmentStore

    private struct InlineImage {
        var attachment: Attachment
        var caption: String
        var sourceURL: URL?
        var isPageCapture: Bool
    }

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
        guard clip.images.reduce(0, { $0 + $1.data.count }) <= Self.maximumImageBytes else {
            throw .importFailed(format: "web clip", reason: "The page images are too large to save.")
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

        var attachmentSearchChanged = false
        if let html = clip.contentHTML?.trimmingCharacters(in: .whitespacesAndNewlines), !html.isEmpty {
            let attachment: Attachment
            if let existing = item.attachments.first(where: { $0.typeIdentifier == "public.html" }) {
                attachment = existing
            } else {
                attachment = try attachments.attach(
                    data: Data(html.utf8),
                    filename: "\(filenameStem(for: item.title)).html",
                    typeIdentifier: "public.html",
                    to: item
                )
            }

            if clip.mode == .fullPage {
                let searchableText = String(clip.contentMarkdown.prefix(1_000_000))
                if attachment.extractedText != searchableText {
                    attachment.extractedText = searchableText
                    attachmentSearchChanged = true
                }
            }
        }

        var inlineImages: [InlineImage] = []
        for (index, image) in clip.images.enumerated() where !image.data.isEmpty {
            let filename = image.filename.trimmingCharacters(in: .whitespacesAndNewlines)
            let stableName = filename.isEmpty ? "web-image-\(index + 1).png" : filename
            let attachment: Attachment
            if let existing = item.attachments.first(where: { $0.filename == stableName }) {
                attachment = existing
            } else {
                attachment = try attachments.attach(
                    data: image.data,
                    filename: stableName,
                    typeIdentifier: image.typeIdentifier,
                    to: item
                )
            }
            let isPageCapture = clip.mode == .fullPage
                && image.sourceURL == nil
                && stableName.hasPrefix("full-page-")
            inlineImages.append(InlineImage(
                attachment: attachment,
                caption: isPageCapture ? "" : image.altText,
                sourceURL: image.sourceURL,
                isPageCapture: isPageCapture
            ))
        }

        if let screenshot = clip.screenshotData,
           !screenshot.isEmpty,
           !item.attachments.contains(where: { $0.filename.contains("-screenshot.") }) {
            let format = screenshotFormat(screenshot)
            let attachment = try attachments.attach(
                data: screenshot,
                filename: "\(filenameStem(for: item.title))-screenshot.\(format.fileExtension)",
                typeIdentifier: format.typeIdentifier,
                to: item
            )
            inlineImages.append(InlineImage(
                attachment: attachment,
                caption: clip.mode == .fullPage ? "Full-page capture" : "Page capture",
                sourceURL: nil,
                isPageCapture: true
            ))
        } else if let screenshot = item.attachments.first(where: { $0.filename.contains("-screenshot.") }) {
            inlineImages.append(InlineImage(
                attachment: screenshot,
                caption: clip.mode == .fullPage ? "Full-page capture" : "Page capture",
                sourceURL: nil,
                isPageCapture: true
            ))
        }

        if item.kind == .note, item.noteDocumentData == nil, !inlineImages.isEmpty {
            let document = noteDocument(for: clip, sourceURL: sourceURL, inlineImages: inlineImages)
            try items.update(item) { $0.setNoteDocument(document) }
        } else if attachmentSearchChanged {
            try items.update(item) { $0.refreshSearchText() }
        }

        return item
    }

    private func noteBody(for clip: WebClip, sourceURL: URL) -> String {
        noteSections(for: clip, sourceURL: sourceURL).joined(separator: "\n\n---\n\n")
    }

    private func noteSections(for clip: WebClip, sourceURL: URL) -> [String] {
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

        let markdown = clip.contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = clip.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = clip.mode == .fullPage ? summary : markdown
        if !content.isEmpty {
            sections.append(content)
        } else if !summary.isEmpty {
            sections.append(summary)
        }

        return sections
    }

    /// Builds the rich note in known sections instead of searching the imported page for a divider.
    /// A clipped page can contain any number of horizontal rules, and a lossless Markdown fallback
    /// can represent every one of them as plain text. Section ownership is the only stable way to
    /// guarantee that the visual capture appears near the top of the note.
    private func noteDocument(
        for clip: WebClip,
        sourceURL: URL,
        inlineImages: [InlineImage]
    ) -> NoteDocument {
        let sections = noteSections(for: clip, sourceURL: sourceURL)
        let content = sections.last ?? ""
        let prefix = sections.dropLast()
        var pieces: [NotePiece] = []

        for section in prefix {
            if !pieces.isEmpty { pieces.append(.object(.divider)) }
            pieces.append(contentsOf: documentPieces(from: section))
        }
        if !pieces.isEmpty { pieces.append(.object(.divider)) }

        let captures = inlineImages.filter(\.isPageCapture)
        pieces.append(contentsOf: captures.map(imagePiece))

        let pageImages = inlineImages.filter { !$0.isPageCapture }
        pieces.append(contentsOf: contentPieces(from: content, images: pageImages))
        return NoteDocument(pieces: pieces.isEmpty ? NoteDocument.empty.pieces : pieces)
    }

    private func contentPieces(from content: String, images: [InlineImage]) -> [NotePiece] {
        let matches = images.compactMap { image -> (range: Range<String.Index>, image: InlineImage)? in
            guard let source = image.sourceURL?.absoluteString else { return nil }
            let pattern = #"!\[[^\]\n]*\]\("#
                + NSRegularExpression.escapedPattern(for: source)
                + #"\)"#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: content,
                    range: NSRange(content.startIndex..., in: content)
                  ),
                  let range = Range(match.range, in: content) else { return nil }
            return (range, image)
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }

        var pieces: [NotePiece] = []
        var cursor = content.startIndex
        var matchedIDs: Set<UUID> = []
        for match in matches where match.range.lowerBound >= cursor {
            pieces.append(contentsOf: documentPieces(from: String(content[cursor..<match.range.lowerBound])))
            pieces.append(imagePiece(match.image))
            matchedIDs.insert(match.image.attachment.id)
            cursor = match.range.upperBound
        }
        pieces.append(contentsOf: documentPieces(from: String(content[cursor...])))

        let unmatched = images.filter { !matchedIDs.contains($0.attachment.id) }
        if !unmatched.isEmpty {
            pieces.insert(contentsOf: unmatched.map(imagePiece), at: 0)
        }
        return pieces
    }

    private func documentPieces(from text: String) -> [NotePiece] {
        let section = text.trimmingCharacters(in: .newlines)
        guard !section.isEmpty else { return [] }
        return NoteBodyImport.document(from: section).pieces
    }

    private func imagePiece(_ image: InlineImage) -> NotePiece {
        .object(.image(
            attachmentID: image.attachment.id,
            caption: NoteRichText(image.caption)
        ))
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

    private func screenshotFormat(_ data: Data) -> (typeIdentifier: String, fileExtension: String) {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return ("public.jpeg", "jpg") }
        return ("public.png", "png")
    }
}
