import Foundation

/// What part of a web page the user asked Elephruit to keep.
public enum WebClipMode: String, Codable, Sendable, Hashable, CaseIterable {
    case article
    case simplifiedArticle
    case selection
    case fullPage
    case bookmark
    case screenshot

    public var displayName: String {
        switch self {
        case .article: "Article"
        case .simplifiedArticle: "Simplified article"
        case .selection: "Selection"
        case .fullPage: "Full page"
        case .bookmark: "Bookmark"
        case .screenshot: "Screenshot"
        }
    }
}

/// One image Safari made durable while clipping a page.
///
/// The bytes travel with the envelope instead of leaving a hotlink behind. A clipped page must
/// remain useful when the source changes, removes an image, or disappears entirely.
public struct WebClipImage: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var sourceURL: URL?
    public var altText: String
    public var filename: String
    public var typeIdentifier: String
    public var data: Data

    public init(
        id: UUID = UUID(),
        sourceURL: URL? = nil,
        altText: String = "",
        filename: String,
        typeIdentifier: String,
        data: Data
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.altText = altText
        self.filename = filename
        self.typeIdentifier = typeIdentifier
        self.data = data
    }
}

/// A self-contained capture produced by the Safari extension.
///
/// The browser owns extraction and the app owns persistence. Keeping the boundary as a Codable
/// value means neither side reaches into the other's sandbox, and a clip can wait safely in the
/// shared inbox while Elephruit is not running.
public struct WebClip: Codable, Sendable, Hashable, Identifiable {
    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    public var mode: WebClipMode
    public var title: String
    public var sourceURL: URL
    public var canonicalURL: URL?
    public var siteName: String?
    public var author: String?
    public var excerpt: String?
    public var contentMarkdown: String
    public var contentHTML: String?
    public var comment: String
    public var tagSlugs: [String]
    public var projectHint: String?
    public var images: [WebClipImage]
    public var screenshotData: Data?
    public var clippedAt: Date

    public init(
        version: Int = WebClip.currentVersion,
        id: UUID = UUID(),
        mode: WebClipMode,
        title: String,
        sourceURL: URL,
        canonicalURL: URL? = nil,
        siteName: String? = nil,
        author: String? = nil,
        excerpt: String? = nil,
        contentMarkdown: String = "",
        contentHTML: String? = nil,
        comment: String = "",
        tagSlugs: [String] = [],
        projectHint: String? = nil,
        images: [WebClipImage] = [],
        screenshotData: Data? = nil,
        clippedAt: Date = Date()
    ) {
        self.version = version
        self.id = id
        self.mode = mode
        self.title = title
        self.sourceURL = sourceURL
        self.canonicalURL = canonicalURL
        self.siteName = siteName
        self.author = author
        self.excerpt = excerpt
        self.contentMarkdown = contentMarkdown
        self.contentHTML = contentHTML
        self.comment = comment
        self.tagSlugs = tagSlugs
        self.projectHint = projectHint
        self.images = images
        self.screenshotData = screenshotData
        self.clippedAt = clippedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case mode
        case title
        case sourceURL
        case canonicalURL
        case siteName
        case author
        case excerpt
        case contentMarkdown
        case contentHTML
        case comment
        case tagSlugs
        case projectHint
        case images
        case screenshotData
        case clippedAt
    }

    /// Older durable inbox envelopes have no `images` key. Decode those as text-only clips so an
    /// extension update can never strand something the user already saved.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        id = try values.decode(UUID.self, forKey: .id)
        mode = try values.decode(WebClipMode.self, forKey: .mode)
        title = try values.decode(String.self, forKey: .title)
        sourceURL = try values.decode(URL.self, forKey: .sourceURL)
        canonicalURL = try values.decodeIfPresent(URL.self, forKey: .canonicalURL)
        siteName = try values.decodeIfPresent(String.self, forKey: .siteName)
        author = try values.decodeIfPresent(String.self, forKey: .author)
        excerpt = try values.decodeIfPresent(String.self, forKey: .excerpt)
        contentMarkdown = try values.decodeIfPresent(String.self, forKey: .contentMarkdown) ?? ""
        contentHTML = try values.decodeIfPresent(String.self, forKey: .contentHTML)
        comment = try values.decodeIfPresent(String.self, forKey: .comment) ?? ""
        tagSlugs = try values.decodeIfPresent([String].self, forKey: .tagSlugs) ?? []
        projectHint = try values.decodeIfPresent(String.self, forKey: .projectHint)
        images = try values.decodeIfPresent([WebClipImage].self, forKey: .images) ?? []
        screenshotData = try values.decodeIfPresent(Data.self, forKey: .screenshotData)
        clippedAt = try values.decodeIfPresent(Date.self, forKey: .clippedAt) ?? Date()
    }

    /// Prefer the page's declared canonical address, but never accept a non-web scheme from it.
    public var preferredSourceURL: URL {
        guard let canonicalURL, canonicalURL.isWebURL else { return sourceURL }
        return canonicalURL
    }
}

extension URL {
    /// Only addresses Safari can have loaded as an ordinary web page are valid clip provenance.
    public var isWebURL: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
