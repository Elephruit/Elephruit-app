import ElephruitCore
import Foundation
import SwiftData

/// The first released schema.
///
/// ### On the numbering
/// Schema versions are `0.0.x` and only the patch component moves. The major and minor components
/// are held at zero deliberately: nothing here has shipped, and a version number that climbs by
/// whole integers implies a compatibility story this project has not made yet. A schema version
/// exists to be *different from its predecessor* so the store can be identified — it is not a
/// statement about how big the change was.
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
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 1) }

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

/// The second schema: time tracking.
///
/// One new entity, ``TimeEntry``, and one relationship on ``Item`` pointing at it. Both are
/// **additive** — nothing existing changes shape and no data is rewritten. A store opened under this
/// version gains an empty table and keeps everything it already had.
///
/// ### Why there is no shapeless version between this and V1
/// There was one, briefly, and it broke the app.
///
/// Phase A2 declared a `SchemaV2` whose `models` were literally `SchemaV1.models` — the entity shapes
/// were identical, and the version existed to mark a *data* change (restricting containment). But the
/// data change was then correctly moved out of the migration and into an offered, post-open repair,
/// which left a schema version that differed from its predecessor in no way at all.
///
/// Core Data identifies a version by a **checksum over its entity shapes**. Two versions with the
/// same shapes have the same checksum, and when a plan contains more than one stage it builds an
/// `NSLightweightMigrationStage` from the set of them and throws
/// `"Duplicate version checksums detected"`. With a single stage that never happened; adding time
/// tracking made it a second stage, and every launch that needed migrating crashed.
///
/// A version with no distinct shape is not a version. No store can be identified as being on it —
/// it is byte-indistinguishable from V1 — so collapsing the two loses nothing and is invisible to
/// any existing library.
///
/// **The rule this establishes:** a `VersionedSchema` earns its number by changing a shape. A change
/// to *data* under unchanged shapes is a repair, and repairs live outside the migration plan, which
/// is where ``ContainmentRepair`` already is.
public enum SchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 2) }

    public static var models: [any PersistentModel.Type] {
        SchemaV1.models + [TimeEntry.self]
    }
}

/// The third schema: an estimate on an item, and an index on its creation date.
///
/// Additive again — one optional attribute and one index. Nothing changes shape, nothing is
/// rewritten, and a store opened under this version gains a nullable column it can ignore.
///
/// ### Why this is still a version rather than a silent change
/// The version identifier is what the `.schema-version` stamp beside the store is compared against,
/// and a mismatch is what triggers the backup in ``PersistenceStack``. A schema change that did not
/// bump the version would migrate real user data with **no backup taken** — which is precisely the
/// bug fixed once already, when the backup was keyed on `stages.isEmpty` and so "silently switched
/// the backup off on exactly the launch that needed it most."
///
/// ### Why the model types are still live, and when that stops being true
/// The freeze described below is not required for an additive change, and the evidence is this
/// codebase: `TimeEntry` — a whole new entity plus a relationship — arrived by lightweight inference
/// under a single declared version and migrates real bytes correctly, which
/// `RealStoreMigrationTests` now demonstrates against a store written by a build that predates it.
///
/// What the freeze *is* required for is the first change that cannot be inferred: a rename, a type
/// change, a value that has to be computed from old data. That needs a `.custom` stage, a stage
/// needs more than one version in `schemas`, and more than one version needs distinct checksums —
/// which live shared types cannot provide. See ADR 0005 for the trigger and the procedure.
public enum SchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 3) }

    public static var models: [any PersistentModel.Type] {
        SchemaV2.models
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
public enum ElephruitMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV3.self]
    }

    /// **Empty, and that is not an oversight.**
    ///
    /// See the note on ``SchemaV2``. While the versioned schemas share live model types, SwiftData
    /// resolves each one's full entity graph — so `SchemaV1`, which never mentions `TimeEntry`, has
    /// it pulled in anyway through `Item.timeEntries`, and comes out byte-identical to `SchemaV2`.
    /// Two versions with the same shape have the same checksum, and a plan holding both throws.
    ///
    /// Declaring one version leaves Core Data to infer the lightweight migration, which is exactly
    /// what it is good at: adding a table and leaving everything else alone. The machinery stays
    /// here for the first change that genuinely needs a custom stage, and that change is also the
    /// one that makes freezing the old model types mandatory rather than optional.
    public static var stages: [MigrationStage] { [] }

}

/// The schema the app currently opens.
public enum CurrentSchema {
    public static var versioned: any VersionedSchema.Type { SchemaV3.self }

    public static var schema: Schema { Schema(versionedSchema: SchemaV3.self) }

    /// Human-readable version, for diagnostics and export archives.
    public static var versionString: String {
        let version = SchemaV3.versionIdentifier
        return "\(version.major).\(version.minor).\(version.patch)"
    }
}
