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

    /// How much clipped markdown may live inline in ``Item/body``.
    ///
    /// A CKRecord holds about a megabyte across all its inline fields, and `body` is the one
    /// column a clip could push past it — ``maximumTextLength`` allows eight million
    /// characters. Past this bound the full article becomes a managed Markdown attachment
    /// (bytes on disk, CKAsset in transit, searchable through its extracted text) and the
    /// body carries an excerpt plus the fact of the attachment. Well under the record limit
    /// on purpose: `searchText` re-folds the body into a second stored column, so the budget
    /// is spent roughly twice.
    public static let maximumInlineBodyLength = 64_000

    /// The excerpt written inline when an article is externalized.
    static let externalizedExcerptLength = 8_000

    /// How much of an externalized article feeds search, through the attachment's
    /// extracted text. Bounded for the same reason ``maximumInlineBodyLength`` is: the
    /// extraction joins `searchText`, which is itself a stored column on the record.
    static let externalizedSearchLength = 32_000

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
        var htmlAttachment: Attachment?
        if let html = clip.contentHTML?.trimmingCharacters(in: .whitespacesAndNewlines), !html.isEmpty {
            let attachment: Attachment
            if let existing = (item.attachments ?? []).first(where: { $0.typeIdentifier == "public.html" }) {
                attachment = existing
            } else {
                attachment = try attachments.attach(
                    data: Data(webClipDocument(fragment: html).utf8),
                    filename: "\(filenameStem(for: item.title)).html",
                    typeIdentifier: "public.html",
                    to: item
                )
            }
            htmlAttachment = attachment

            // Bounded because this extraction joins `searchText`, a stored column on the
            // item's own record; the sync budget is the bound's reason and its size.
            let searchableText = String(clip.contentMarkdown.prefix(Self.externalizedSearchLength))
            if attachment.extractedText != searchableText {
                attachment.extractedText = searchableText
                attachmentSearchChanged = true
            }
        }

        // Past the inline bound the body carries an excerpt, so the whole article becomes a
        // managed Markdown attachment: bytes on disk like every managed copy, a CKAsset in
        // transit, openable with anything that reads text. Search rides the HTML attachment's
        // extraction when there is one, and this file's own when there is not.
        if clip.contentMarkdown.count > Self.maximumInlineBodyLength,
           (item.attachments ?? []).first(where: { $0.typeIdentifier == "net.daringfireball.markdown" }) == nil {
            let article = try attachments.attach(
                data: Data(clip.contentMarkdown.utf8),
                filename: "\(filenameStem(for: item.title)).md",
                typeIdentifier: "net.daringfireball.markdown",
                to: item
            )
            if htmlAttachment == nil {
                article.extractedText = String(clip.contentMarkdown.prefix(Self.externalizedSearchLength))
                attachmentSearchChanged = true
            }
        }

        var inlineImages: [InlineImage] = []
        for (index, image) in clip.images.enumerated() where !image.data.isEmpty {
            let filename = image.filename.trimmingCharacters(in: .whitespacesAndNewlines)
            let stableName = filename.isEmpty ? "web-image-\(index + 1).png" : filename
            let attachment: Attachment
            if let existing = (item.attachments ?? []).first(where: { $0.filename == stableName }) {
                attachment = existing
            } else {
                attachment = try attachments.attach(
                    data: image.data,
                    id: image.id,
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
           !(item.attachments ?? []).contains(where: { $0.filename.contains("-screenshot.") }) {
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
        } else if let screenshot = (item.attachments ?? []).first(where: { $0.filename.contains("-screenshot.") }) {
            inlineImages.append(InlineImage(
                attachment: screenshot,
                caption: clip.mode == .fullPage ? "Full-page capture" : "Page capture",
                sourceURL: nil,
                isPageCapture: true
            ))
        }

        if item.kind == .note,
           item.noteDocumentData == nil,
           htmlAttachment != nil || !inlineImages.isEmpty {
            let document = noteDocument(
                for: clip,
                sourceURL: sourceURL,
                htmlAttachment: htmlAttachment,
                inlineImages: inlineImages
            )
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
        var sections = metadataSections(for: clip, sourceURL: sourceURL)

        // A full-page clip is the visual capture. Its DOM text belongs in attachment search
        // metadata, not in the editor beneath the image. Page-provided excerpts are especially
        // unreliable here: some sites expose their entire flattened home page as an "excerpt".
        guard clip.mode != .fullPage else { return sections }

        let markdown = clip.contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = clip.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !markdown.isEmpty {
            sections.append(Self.inlineBody(for: markdown))
        } else if !summary.isEmpty {
            sections.append(summary)
        }

        return sections
    }

    /// The markdown as the note carries it: whole when it fits, an excerpt when it does not.
    ///
    /// Pure, so the bound can be asserted without clipping a real page.
    static func inlineBody(for markdown: String) -> String {
        guard markdown.count > maximumInlineBodyLength else { return markdown }
        let cut = markdown.prefix(externalizedExcerptLength)
        // Back up to whitespace so the excerpt never ends mid-word.
        let excerpt = cut.lastIndex(where: \.isWhitespace).map { String(cut[..<$0]) } ?? String(cut)
        return excerpt + "\n\n*The article is longer than a note holds — the whole text is attached.*"
    }

    private func metadataSections(for clip: WebClip, sourceURL: URL) -> [String] {
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
        return sections
    }

    /// Builds the rich note in known sections instead of searching the imported page for a divider.
    /// A clipped page can contain any number of horizontal rules, and a lossless Markdown fallback
    /// can represent every one of them as plain text. Section ownership is the only stable way to
    /// guarantee that the visual capture appears near the top of the note.
    private func noteDocument(
        for clip: WebClip,
        sourceURL: URL,
        htmlAttachment: Attachment?,
        inlineImages: [InlineImage]
    ) -> NoteDocument {
        if usesLiveHTML(clip.mode), let htmlAttachment {
            var pieces: [NotePiece] = []
            for section in metadataSections(for: clip, sourceURL: sourceURL) {
                if !pieces.isEmpty { pieces.append(.object(.divider)) }
                pieces.append(contentsOf: documentPieces(from: section))
            }
            if !pieces.isEmpty { pieces.append(.object(.divider)) }
            pieces.append(.object(.webClip(attachmentID: htmlAttachment.id)))
            return NoteDocument(pieces: pieces)
        }

        let sections = noteSections(for: clip, sourceURL: sourceURL)
        let content = clip.mode == .fullPage ? "" : sections.last ?? ""
        let prefix = clip.mode == .fullPage ? sections[...] : sections.dropLast()
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

    private func usesLiveHTML(_ mode: WebClipMode) -> Bool {
        switch mode {
        case .article, .simplifiedArticle, .selection: true
        case .fullPage, .bookmark, .screenshot: false
        }
    }

    private func webClipDocument(fragment: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src elephruit-attachment: data:; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; frame-src 'none';">
          <style>
            :root { color-scheme: light dark; }
            html, body { margin: 0; max-width: 100%; overflow-x: auto; }
            body { width: max-content; min-width: 100%; }
            img { max-width: 100%; height: auto; }
          </style>
        </head>
        <body>\(fragment)</body>
        </html>
        """
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
