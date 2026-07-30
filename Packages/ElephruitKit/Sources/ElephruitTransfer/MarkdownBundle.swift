import ElephruitCore
import Foundation

/// Reads and writes Markdown with YAML front-matter.
///
/// The front-matter is deliberately minimal and flat — a handful of scalar keys and one list —
/// so that the files remain readable, editable by hand, and importable by other tools. Anything
/// that cannot be expressed that way lives in the JSON archive written alongside, which is why
/// the Markdown bundle never claims to be complete on its own.
public enum MarkdownFrontMatter {
    /// The delimiter, per the convention every Markdown tool follows.
    static let fence = "---"

    /// Renders front-matter plus body.
    public static func render(_ item: ArchiveItem, tagSlugs: [String]) -> String {
        var lines: [String] = [fence]

        lines.append("id: \(item.id.uuidString)")
        lines.append("kind: \(item.kind)")
        lines.append("title: \(yamlScalar(item.title))")
        lines.append("created: \(iso(item.createdAt))")
        lines.append("updated: \(iso(item.updatedAt))")

        if item.status != ItemStatus.none.rawValue { lines.append("status: \(item.status)") }
        if item.priority != Priority.normal.rawValue { lines.append("priority: \(item.priority)") }
        if let date = item.startAt { lines.append("start: \(iso(date))") }
        if let date = item.dueAt { lines.append("due: \(iso(date))") }
        if let date = item.deferUntil { lines.append("defer: \(iso(date))") }
        if let date = item.completedAt { lines.append("completed: \(iso(date))") }
        if let date = item.archivedAt { lines.append("archived: \(iso(date))") }
        if let date = item.deletedAt { lines.append("deleted: \(iso(date))") }
        if item.isFavorite { lines.append("favorite: true") }
        if item.isPinned { lines.append("pinned: true") }
        if let dayKey = item.dayKey { lines.append("day: \(dayKey)") }
        if let url = item.sourceURL { lines.append("url: \(yamlScalar(url))") }
        if let parentID = item.parentID { lines.append("parent: \(parentID.uuidString)") }

        if !tagSlugs.isEmpty {
            lines.append("tags: [\(tagSlugs.map(yamlScalar).joined(separator: ", "))]")
        }

        lines.append(fence)
        lines.append("")
        lines.append(item.body)

        return lines.joined(separator: "\n")
    }

    /// Splits a file into its front-matter fields and its body.
    ///
    /// A file with no front-matter is perfectly valid — that is the common case when importing
    /// Markdown from elsewhere — and yields an empty field dictionary with the whole text as body.
    public static func parse(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.components(separatedBy: .newlines)

        guard lines.first?.trimmingCharacters(in: .whitespaces) == fence else {
            return ([:], text)
        }

        var fields: [String: String] = [:]
        var bodyStartIndex: Int?

        for index in 1..<lines.count {
            let line = lines[index]

            if line.trimmingCharacters(in: .whitespaces) == fence {
                bodyStartIndex = index + 1
                break
            }

            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fields[key.lowercased()] = unquote(value)
        }

        guard let bodyStartIndex, bodyStartIndex <= lines.count else {
            // An unterminated fence means it was not front-matter after all.
            return ([:], text)
        }

        let body = lines[bodyStartIndex...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)

        return (fields, body)
    }

    /// Reads a `tags: [a, b]` list.
    public static func parseList(_ value: String) -> [String] {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
            .split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Scalars

    /// Quotes a value only when YAML would otherwise misread it.
    ///
    /// Minimal quoting keeps files pleasant to read by hand, which is the entire reason for
    /// choosing Markdown as the human-readable format.
    public static func yamlScalar(_ value: String) -> String {
        let needsQuoting = value.isEmpty
            || value.contains(":")
            || value.contains("#")
            || value.contains(",")
            || value.contains("[")
            || value.contains("]")
            || value.hasPrefix(" ")
            || value.hasSuffix(" ")
            || value.contains("\n")

        guard needsQuoting else { return value }

        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    public static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the class is not `Sendable`,
    /// so a shared static instance of it cannot exist under Swift 6 concurrency checking, and a
    /// per-call instance would be wasteful. The format style is a value and is `Sendable`.
    public static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    public static func date(from value: String) -> Date? {
        try? Date(value, strategy: .iso8601)
    }

    /// A filename safe on every filesystem, derived from a title.
    ///
    /// The identifier is appended so two notes with the same title cannot collide, and so an
    /// exported file can be traced back to its record.
    public static func filename(for item: ArchiveItem) -> String {
        let base = item.title.isEmpty
            ? "untitled"
            : String(TextNormalizer.slug(item.title).replacingOccurrences(of: "/", with: "-").prefix(60))

        let stem = base.isEmpty ? "untitled" : base
        return "\(stem)-\(item.id.uuidString.prefix(8)).md"
    }

    /// Which subdirectory an item's file belongs in. Grouping by kind makes a bundle navigable.
    public static func directoryName(forKind kind: String) -> String {
        guard let itemKind = ItemKind(rawValue: kind) else { return "Other" }
        return itemKind.pluralDisplayName
    }
}

/// Writes a Markdown bundle.
///
/// Layout:
/// ```
/// <destination>/
///   README.md                 ← what this bundle is, and its counts
///   elephruit-archive.json   ← the lossless companion
///   Notes/…                   ← one .md per item, grouped by kind
///   Tasks/…
///   Attachments/<uuid>/…      ← Phase 2
/// ```
@MainActor
struct MarkdownBundleWriter {
    let archive: ArchiveDocument

    func write(to destination: URL) throws(AppError) -> ExportReport {
        let fileManager = FileManager.default
        var fileCount = 0

        // Tag slugs are resolved once so each file's front-matter can name tags readably while
        // the archive keeps identifiers.
        let slugsByTagID = Dictionary(
            archive.tags.map { ($0.id, $0.slug) },
            uniquingKeysWith: { first, _ in first }
        )

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            for item in archive.items {
                let directory = destination.appending(
                    path: MarkdownFrontMatter.directoryName(forKind: item.kind),
                    directoryHint: .isDirectory
                )
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

                let slugs = item.tagIDs.compactMap { slugsByTagID[$0] }.sorted()
                let contents = MarkdownFrontMatter.render(item, tagSlugs: slugs)
                let fileURL = directory.appending(
                    path: MarkdownFrontMatter.filename(for: item),
                    directoryHint: .notDirectory
                )

                guard let data = contents.data(using: .utf8) else {
                    throw AppError.exportFailed(reason: "Could not encode “\(item.title)” as UTF-8.")
                }
                try data.write(to: fileURL, options: [.atomic])
                fileCount += 1
            }

            // The archive rides along, so the bundle is both readable and lossless.
            let archiveData = try archive.encoded()
            try archiveData.write(
                to: destination.appending(path: "elephruit-archive.json", directoryHint: .notDirectory),
                options: [.atomic]
            )
            fileCount += 1

            if let readme = makeReadme().data(using: .utf8) {
                try readme.write(
                    to: destination.appending(path: "README.md", directoryHint: .notDirectory),
                    options: [.atomic]
                )
                fileCount += 1
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw .writeFailed(path: destination.path(percentEncoded: false), reason: error.localizedDescription)
        }

        return ExportReport(
            format: .markdownBundle,
            destination: destination,
            itemCount: archive.items.count,
            fileCount: fileCount,
            summary: archive.summary
        )
    }

    /// Explains the bundle to whoever opens it later — possibly the user, years from now,
    /// without Elephruit installed.
    private func makeReadme() -> String {
        """
        # Elephruit export

        Exported \(MarkdownFrontMatter.iso(archive.exportedAt))
        Schema version \(archive.schemaVersion), archive format \(archive.formatVersion).

        Contains \(archive.summary).

        ## What is here

        - **Markdown files**, grouped into folders by kind. Each has YAML front-matter carrying
          its identifier, dates, state, and tags. These are plain text and will outlive any app.
        - **`elephruit-archive.json`** — the complete, lossless record, including links,
          collection order, and saved searches. Import this file back into Elephruit to restore
          everything exactly, identifiers included.

        The Markdown files are for reading and for other tools. The JSON archive is the one to
        keep if you keep only one.
        """
    }
}

/// Writes CSV tables.
///
/// Explicitly a convenience, not a backup: note bodies, links, and collection order are not
/// representable in a flat table, and pretending otherwise would be the sort of half-truth that
/// costs someone their data.
@MainActor
public struct CSVWriter {
    let archive: ArchiveDocument

    func write(to destination: URL) throws(AppError) -> ExportReport {
        let fileManager = FileManager.default
        var fileCount = 0

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            let slugsByTagID = Dictionary(
                archive.tags.map { ($0.id, $0.slug) },
                uniquingKeysWith: { first, _ in first }
            )
            let titlesByItemID = Dictionary(
                archive.items.map { ($0.id, $0.title) },
                uniquingKeysWith: { first, _ in first }
            )

            var itemRows = [
                "id,kind,title,status,priority,created,updated,due,completed,parent,tags,favorite,pinned,archived,deleted"
            ]
            for item in archive.items {
                let tags = item.tagIDs.compactMap { slugsByTagID[$0] }.sorted().joined(separator: " ")
                itemRows.append(
                    [
                        item.id.uuidString,
                        item.kind,
                        item.title,
                        item.status,
                        item.priority,
                        MarkdownFrontMatter.iso(item.createdAt),
                        MarkdownFrontMatter.iso(item.updatedAt),
                        item.dueAt.map(MarkdownFrontMatter.iso) ?? "",
                        item.completedAt.map(MarkdownFrontMatter.iso) ?? "",
                        item.parentID.flatMap { titlesByItemID[$0] } ?? "",
                        tags,
                        item.isFavorite ? "true" : "false",
                        item.isPinned ? "true" : "false",
                        item.archivedAt == nil ? "false" : "true",
                        item.deletedAt == nil ? "false" : "true",
                    ]
                    .map(Self.escape)
                    .joined(separator: ",")
                )
            }
            try writeRows(itemRows, named: "items.csv", in: destination)
            fileCount += 1

            var tagRows = ["id,name,slug,color,implicit"]
            for tag in archive.tags {
                tagRows.append(
                    [tag.id.uuidString, tag.name, tag.slug, tag.colorName ?? "", tag.isImplicit ? "true" : "false"]
                        .map(Self.escape)
                        .joined(separator: ",")
                )
            }
            try writeRows(tagRows, named: "tags.csv", in: destination)
            fileCount += 1
        } catch let error as AppError {
            throw error
        } catch {
            throw .writeFailed(path: destination.path(percentEncoded: false), reason: error.localizedDescription)
        }

        return ExportReport(
            format: .csv,
            destination: destination,
            itemCount: archive.items.count,
            fileCount: fileCount,
            summary: "\(archive.items.count) items and \(archive.tags.count) tags, without bodies or links"
        )
    }

    private func writeRows(_ rows: [String], named name: String, in directory: URL) throws(AppError) {
        // A UTF-8 BOM, so spreadsheet applications read non-ASCII correctly instead of showing
        // mojibake for every accented character.
        let bom = Data([0xEF, 0xBB, 0xBF])
        guard let body = rows.joined(separator: "\r\n").data(using: .utf8) else {
            throw AppError.exportFailed(reason: "Could not encode \(name) as UTF-8.")
        }
        try Exporter.writeAtomically(bom + body, to: directory.appending(path: name, directoryHint: .notDirectory))
    }

    /// RFC 4180 quoting.
    public static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
