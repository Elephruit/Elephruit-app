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

/// The fourth schema: the People module.
///
/// Three new entities — ``PersonObservationRecord``, ``PersonRelationship``, ``PersonCelebration`` —
/// and thirteen new optional attributes on ``PersonProfile``. **Additive throughout.** Nothing
/// existing changes shape, no value is rewritten, and a store opened under this version gains three
/// empty tables and a set of nullable columns it is free to ignore.
///
/// ### Why lightweight inference is still the right call at three entities
/// ADR 0005 reserves the model-type freeze for the first change that *cannot* be inferred: a rename,
/// a type change, a value computed from old data. There is none here. The evidence that inference
/// handles this shape is `SchemaV2`, which added a whole entity plus a relationship and migrates
/// real bytes correctly — `RealStoreMigrationTests` demonstrates it against a store written by a
/// build that predates `TimeEntry`. Three entities is the same operation three times.
///
/// ### Why it is a version at all
/// For the reason spelled out on ``SchemaV3``: the version identifier is what the `.schema-version`
/// stamp beside the store is compared against, and a mismatch is what triggers the backup in
/// ``ElephruitPersistence/PersistenceStack``. A schema change that did not bump the version would
/// migrate real user data with no backup taken.
///
/// ### What is deliberately *not* here
/// No entity for groups. A static group is an ``ItemCollection`` — ordered, explicit membership,
/// already built and already tested — and a smart group is a ``SavedSearch``, which stores a query
/// string that survives version changes and exports as text. Standing rule R5 in `docs/18` asks for
/// proof that the existing shape cannot do the job before a new stored one is added, and for groups
/// there is no such proof to offer: it can.
public enum SchemaV4: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 4) }

    public static var models: [any PersistentModel.Type] {
        SchemaV3.models + [
            PersonObservationRecord.self,
            PersonRelationship.self,
            PersonCelebration.self,
        ]
    }
}

/// The fifth schema: the address book as the CRM's starting population.
///
/// Three new entities — ``SystemContactLink``, ``ImportedContactValue``, ``ContactImportSession`` —
/// and nothing else. **Additive**, so a store opened under this version gains three empty tables and
/// keeps everything it had. `PersonProfile` is untouched: `contactsIdentifier` was already there and
/// is now mirrored from the link rather than replaced, which is what keeps every view written before
/// this slice working unchanged.
///
/// ### Why lightweight inference is still right
/// The same argument as `SchemaV4`, with more evidence behind it now: `TimeEntry` added an entity and
/// a relationship under a single declared version and migrates real bytes correctly, and `SchemaV4`
/// did it three times over. `RealStoreMigrationTests` carries a store written before any of them all
/// the way here. ADR 0005 reserves the model-type freeze for the first change that cannot be
/// inferred — a rename, a type change, a computed value — and there is none.
public enum SchemaV5: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 5) }

    public static var models: [any PersistentModel.Type] {
        SchemaV4.models + [
            SystemContactLink.self,
            ImportedContactValue.self,
            ContactImportSession.self,
        ]
    }
}

/// The sixth schema: the calendar module.
///
/// Two new entities — ``CalendarSetRecord`` and ``EventTemplateRecord`` — and nothing else.
/// **Additive**, so a store opened under this version gains two empty tables and keeps everything it
/// had.
///
/// ### What is deliberately *not* here
/// **No entity for an event.** EventKit is authoritative for events and always will be; a table of
/// them in this store would be a second copy that can disagree with the first, which is precisely
/// the failure `docs/03-storage-matrix.md` exists to prevent. The local cache that makes the
/// calendar work offline and makes search fast is a *derived* SQLite sidecar beside the search
/// index, deletable without loss and rebuilt from EventKit — the same shape, and for the same
/// reasons, as `SearchIndex.sqlite`.
///
/// **No entity for an event's links.** A meeting somebody has attached people, notes, and a project
/// to is an ``Item`` of kind `.meeting` carrying an ``EventReference``, which is the shape this
/// store has had since milestone 1. Linking a person to it is an ``ItemLink``; attaching a file is
/// an ``Attachment``; the debrief is its body. Standing rule R5 asks for proof that the existing
/// shape cannot do the job before a new one is added, and here there is no such proof to offer:
/// every one of those already works, and a parallel table would need its own search indexing, its
/// own export, its own trash, and its own answer to what happens when a person is merged.
///
/// ### Why lightweight inference is still right
/// The same argument as `SchemaV4` and `SchemaV5`, with more evidence behind it each time.
/// `TimeEntry` added an entity and a relationship under a single declared version and migrates real
/// bytes correctly; `SchemaV4` did it three times over and `SchemaV5` three more. ADR 0005 reserves
/// the model-type freeze for the first change that cannot be inferred — a rename, a type change, a
/// computed value — and there is none.
public enum SchemaV6: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 6) }

    public static var models: [any PersistentModel.Type] {
        SchemaV5.models + [
            CalendarSetRecord.self,
            EventTemplateRecord.self,
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
public enum ElephruitMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV6.self]
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
    public static var versioned: any VersionedSchema.Type { SchemaV6.self }

    public static var schema: Schema { Schema(versionedSchema: SchemaV6.self) }

    /// Human-readable version, for diagnostics and export archives.
    public static var versionString: String {
        let version = SchemaV6.versionIdentifier
        return "\(version.major).\(version.minor).\(version.patch)"
    }
}
