import Foundation
import SwiftData

/// The first released schema.
///
/// Versioned from day one, and opened through a ``EverythingMigrationPlan`` even though
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
public enum EverythingMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}

/// The schema the app currently opens.
public enum CurrentSchema {
    public static var versioned: any VersionedSchema.Type { SchemaV1.self }

    public static var schema: Schema { Schema(versionedSchema: SchemaV1.self) }

    /// Human-readable version, for diagnostics and export archives.
    public static var versionString: String {
        let version = SchemaV1.versionIdentifier
        return "\(version.major).\(version.minor).\(version.patch)"
    }
}
