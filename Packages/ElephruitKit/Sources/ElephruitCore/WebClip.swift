import Foundation

/// What part of a web page the user asked Elephruit to keep.
public enum WebClipMode: String, Codable, Sendable, Hashable, CaseIterable {
    case article
    case selection
    case fullPage
    case bookmark
    case screenshot

    public var displayName: String {
        switch self {
        case .article: "Article"
        case .selection: "Selection"
        case .fullPage: "Full page"
        case .bookmark: "Bookmark"
        case .screenshot: "Screenshot"
        }
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
        self.screenshotData = screenshotData
        self.clippedAt = clippedAt
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
