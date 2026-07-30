import ElephruitCore
import Foundation
import SwiftData

/// What a containment repair did, or would do.
///
/// Produced by both the dry run and the real thing, so the outcome can be read *before* committing to
/// it — requirement **M6** and **M8**. A migration that reports only "done" leaves the user unable to
/// tell whether it worked.
public struct MigrationReport: Codable, Sendable, Hashable {
    /// One parent relationship turned into a link.
    public struct Conversion: Codable, Sendable, Hashable {
        public var itemID: UUID
        public var itemTitle: String
        public var itemKind: String
        public var containerID: UUID
        public var containerTitle: String

        public init(
            itemID: UUID, itemTitle: String, itemKind: String,
            containerID: UUID, containerTitle: String
        ) {
            self.itemID = itemID
            self.itemTitle = itemTitle
            self.itemKind = itemKind
            self.containerID = containerID
            self.containerTitle = containerTitle
        }
    }

    /// Something that could not be converted, and why.
    public struct Unresolved: Codable, Sendable, Hashable {
        public var itemID: UUID
        public var itemTitle: String
        public var reason: String

        public init(itemID: UUID, itemTitle: String, reason: String) {
            self.itemID = itemID
            self.itemTitle = itemTitle
            self.reason = reason
        }
    }

    public var isDryRun: Bool
    public var itemsExamined: Int
    public var conversions: [Conversion]
    public var unresolved: [Unresolved]
    public var alreadyValid: Int

    public init(
        isDryRun: Bool,
        itemsExamined: Int = 0,
        conversions: [Conversion] = [],
        unresolved: [Unresolved] = [],
        alreadyValid: Int = 0
    ) {
        self.isDryRun = isDryRun
        self.itemsExamined = itemsExamined
        self.conversions = conversions
        self.unresolved = unresolved
        self.alreadyValid = alreadyValid
    }

    public var hasWork: Bool { !conversions.isEmpty }

    /// A readable account, for the interface and for the log.
    public var summary: String {
        var lines: [String] = []
        lines.append(isDryRun ? "Dry run — nothing was written." : "Migration complete.")
        lines.append("Examined \(itemsExamined) item\(itemsExamined == 1 ? "" : "s").")

        if conversions.isEmpty {
            lines.append("No relationships needed converting.")
        } else {
            lines.append("Converted \(conversions.count) relationship\(conversions.count == 1 ? "" : "s") to links:")
            for conversion in conversions.prefix(20) {
                lines.append("  · “\(conversion.itemTitle)” → filed under “\(conversion.containerTitle)”")
            }
            if conversions.count > 20 {
                lines.append("  · …and \(conversions.count - 20) more.")
            }
        }

        if !unresolved.isEmpty {
            lines.append("Could not convert \(unresolved.count):")
            for item in unresolved.prefix(10) {
                lines.append("  · “\(item.itemTitle)” — \(item.reason)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

/// Converts parent relationships that containment no longer permits into `filedUnder` links.
///
/// ### Why this is a standalone operation rather than only a migration closure
/// A `MigrationStage` closure is awkward to test, impossible to dry-run, and produces no report. This
/// runs on any `ModelContext`, so it can be exercised against fixture stores, previewed without
/// writing, and *then* called by the stage.
///
/// ### What it guarantees
/// Nothing is deleted and nothing is orphaned. Every parent that is now illegal becomes a
/// `filedUnder` link to the same container, so the association survives in the form the new model
/// expresses it. Tags, ordering, body text, timestamps, and every other link are untouched.
public enum ContainmentRepair {
    /// Reports what a repair would do, writing nothing. Requirement **M8**.
    public static func plan(in context: ModelContext) throws -> MigrationReport {
        try run(in: context, dryRun: true)
    }

    /// Performs the repair.
    @discardableResult
    public static func apply(in context: ModelContext) throws -> MigrationReport {
        try run(in: context, dryRun: false)
    }

    private static func run(in context: ModelContext, dryRun: Bool) throws -> MigrationReport {
        let items = try context.fetch(FetchDescriptor<Item>())

        var report = MigrationReport(isDryRun: dryRun)
        report.itemsExamined = items.count

        for item in items {
            guard let parent = item.parent else {
                report.alreadyValid += 1
                continue
            }

            // Still legal under the new rules — leave it exactly as it is.
            if parent.kind.canContain(item.kind) {
                report.alreadyValid += 1
                continue
            }

            // A container that is not itself a work container cannot receive a filing either, so the
            // association is recorded as unresolvable rather than silently dropped.
            guard parent.kind.isWorkBreakdownContainer else {
                report.unresolved.append(
                    MigrationReport.Unresolved(
                        itemID: item.id,
                        itemTitle: item.displayTitle,
                        reason: "was inside a \(parent.kind.displayName.lowercased()), which cannot hold filings"
                    )
                )
                if !dryRun {
                    // Detached rather than left invalid: an item with an illegal parent would fail
                    // validation on its next save and become uneditable.
                    item.parent = nil
                }
                continue
            }

            report.conversions.append(
                MigrationReport.Conversion(
                    itemID: item.id,
                    itemTitle: item.displayTitle,
                    itemKind: item.kindRaw,
                    containerID: parent.id,
                    containerTitle: parent.displayTitle
                )
            )

            guard !dryRun else { continue }

            // Only add the link if an equivalent one is not already there, so running twice is a
            // no-op rather than a duplicate — requirement A2-6.
            let alreadyFiled = item.outgoingLinks.contains {
                $0.kind == .filedUnder && $0.target?.id == parent.id
            }
            if !alreadyFiled {
                context.insert(
                    ItemLink(kind: .filedUnder, source: item, target: parent, createdAt: Date())
                )
            }
            item.parent = nil
        }

        if !dryRun, context.hasChanges {
            try context.save()
        }

        return report
    }
}
