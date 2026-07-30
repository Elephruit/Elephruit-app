import ElephruitCore
import Foundation
import SwiftData
import Synchronization

/// The first released schema.
///
/// Versioned from day one, and opened through a ``ElephruitMigrationPlan`` even though
/// there is only one version, so the first real migration is an *added stage* rather than
/// the introduction of a mechanism. See `docs/05-cloudkit-and-migrations.md`.
///
/// ### When v2 arrives
/// If a change to an entity is not lightweight, that entity's v1 shape is snapshotted as
/// a nested type inside this enum and referenced here, so this schema stays compilable
/// and its migration stays testable forever. Until then, referencing the live types is
/// correct and avoids duplicating nine entities for no benefit.
public enum SchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [
            Item.self,
            Tag.self,
            ItemLink.self,
            Attachment.self,
            ItemCollection.self,
            CollectionMembership.self,
            SavedSearch.self,
            PersonProfile.self,
            EventReference.self,
        ]
    }
}

/// The second schema.
///
/// The entity *shapes* are identical to ``SchemaV1``: the attributes added along the way —
/// `titleMatchKey`, `dueSortKey`, `completionPromptDismissedAt` — are all optional or defaulted and
/// migrate lightweightly. What makes this a new version is the **data** change: containment was
/// restricted to the work-breakdown structure, so parent relationships the new rules no longer
/// permit have to become `filedUnder` links.
///
/// The model types are shared rather than snapshotted, which is correct precisely because no shape
/// changed. The moment one does, V1's types get frozen into this file — the rule in
/// `docs/05-cloudkit-and-migrations.md`, which costs nothing to follow until it is needed.
public enum SchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] { SchemaV1.models }
}

/// The migration path from the first released schema to the current one.
///
/// Rules, from `docs/05-cloudkit-and-migrations.md`:
/// 1. Additive changes are lightweight stages — still declared, still tested.
/// 2. Anything else is a `.custom` stage with a test that builds a store at version *N*,
///    migrates it, and asserts on the version *N+1* contents.
/// 3. Every released version stays in source forever.
/// 4. A store backup is written before any non-lightweight stage runs.
/// 5. Migration failure surfaces ``AppError/migrationFailed(fromVersion:toVersion:backupPath:)``
///    and a recovery state. It is never fatal, and it never deletes anything.
public enum ElephruitMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [containmentRepair]
    }

    /// V1 to V2: parent relationships containment no longer permits become `filedUnder` links.
    ///
    /// Runs in `didMigrate`, with the new schema already in place, so the repair operates on exactly
    /// the model the rest of the app uses rather than on an intermediate shape.
    ///
    /// The closure is deliberately thin. Everything it does lives in ``ContainmentRepair``, which can
    /// be dry-run, reported on, and tested against fixture stores — none of which is possible inside
    /// a migration closure.
    static let containmentRepair = MigrationStage.custom(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            let report = try ContainmentRepair.apply(in: context)
            MigrationReportStore.record(report)

            Diagnostics.persistence.info(
                "Containment repair: examined \(report.itemsExamined, privacy: .public), converted \(report.conversions.count, privacy: .public), unresolved \(report.unresolved.count, privacy: .public)"
            )
        }
    )
}

/// Carries the last migration report out of the stage closure.
///
/// A migration runs deep inside `ModelContainer`'s initialiser, which returns a container and nothing
/// else. Without somewhere to put it, the report the user is entitled to see would go to the log and
/// be lost.
public enum MigrationReportStore {
    /// A `Mutex` rather than a lock behind `nonisolated(unsafe)`.
    ///
    /// The hygiene suite forbids that annotation and was right to flag the first attempt here: a
    /// migration report is not a special case, and "it is only written once" is exactly the reasoning
    /// that precedes a data race. `Mutex` is `Sendable`, so a `static let` needs no escape hatch.
    private static let stored = Mutex<MigrationReport?>(nil)

    static func record(_ report: MigrationReport) {
        stored.withLock { $0 = report }
    }

    /// Takes the report, clearing it. Called once by the shell after the store opens.
    public static func take() -> MigrationReport? {
        stored.withLock { value in
            let report = value
            value = nil
            return report
        }
    }
}

/// The schema the app currently opens.
public enum CurrentSchema {
    public static var versioned: any VersionedSchema.Type { SchemaV2.self }

    public static var schema: Schema { Schema(versionedSchema: SchemaV2.self) }

    /// Human-readable version, for diagnostics and export archives.
    public static var versionString: String {
        let version = SchemaV2.versionIdentifier
        return "\(version.major).\(version.minor).\(version.patch)"
    }
}
