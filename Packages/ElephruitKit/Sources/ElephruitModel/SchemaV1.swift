import ElephruitCore
import Foundation
import SwiftData

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

    /// V1 to V2.
    ///
    /// **Lightweight, on purpose.** No entity shape changed, so opening the store needs to do
    /// nothing but restamp the version.
    ///
    /// The consequential part — converting parent relationships into `filedUnder` links — is
    /// deliberately *not* here. A `didMigrate` closure runs unattended, deep inside
    /// `ModelContainer`'s initialiser, the first time the user happens to launch. That is precisely
    /// the shape of decision the app is not supposed to make on its own.
    ///
    /// So ``ContainmentRepair`` runs after the store is open, only when the user says so, and only
    /// after showing them exactly what it will do. It is idempotent and dry-runnable, which is what
    /// makes deferring it safe rather than merely delayed.
    static let containmentRepair = MigrationStage.lightweight(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self
    )
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
