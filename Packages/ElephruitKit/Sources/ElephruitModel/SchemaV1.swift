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

/// The fourth schema introduced person-record metadata.
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

/// The sixth schema: the fields a linked contact needs in order to be corrected in full.
///
/// Four nullable columns on `PersonProfile` — `departmentName`, `middleName`, `namePrefix`,
/// `nameSuffix` — and no new entity. **Additive**, so a store opened under this version gains four
/// empty columns and keeps every byte it had.
///
/// ### Why it exists at all
/// Contacts has held these since long before this app did, so a person imported from the address book
/// arrived with a department and a suffix that the CRM simply dropped. That was tolerable while the
/// integration was read-only — nothing was going to be written back, so nothing was going to be lost
/// on the way out. It stopped being tolerable the moment an edit could travel in the other direction:
/// a write assembled from a model missing these fields would offer to blank them.
///
/// ### Why lightweight inference is still right
/// The same argument as `SchemaV4` and `SchemaV5`, and a weaker case than either: no entity, no
/// relationship, no rename, no type change. Nullable columns are precisely what Core Data's inference
/// exists for. ADR 0005 still reserves the model-type freeze for the first change that cannot be
/// inferred, and this is not it.
public enum SchemaV6: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 6) }

    public static var models: [any PersistentModel.Type] { SchemaV5.models }
}

/// The seventh schema: the Tasks module.
///
/// **No new entities.** Twenty-one new attributes on ``Item`` — the reminder and its ownership, the
/// planning marks, the checklist blob, the recurrence-series identity, the external-reminder link,
/// and the migration's review marker — plus one on ``SavedSearch`` for a smart list's rules. Every
/// one is optional or defaulted, so this is additive throughout: a store opened under this version
/// gains a set of nullable columns it is free to ignore, and nothing existing changes shape.
///
/// ### Why so many columns rather than a satellite entity
/// A `TaskDetail` entity hanging off `Item` was the alternative, and it is worse in the two places
/// that matter. Every task view would fault in a second row to decide whether a task is in Today —
/// which is the query that runs most often and has the tightest budget — and every one of these
/// fields would have to be optional *twice*: once because the column is nullable and once because
/// the satellite might be absent. `Item` is already a wide row by decision (ADR 0002), and
/// `ItemFields` plus `ItemValidator` are the mechanism that stops a note acquiring a task's columns.
/// That mechanism is extended here rather than worked around.
///
/// ### What is deliberately *not* here
/// - **No new date column.** `dueAt` becomes the deadline and `startAt` the availability date; both
///   already existed. Adding a third would have meant migrating live data on a guess about what an
///   old value meant, which is exactly what `TaskDateMigration` refuses to do.
/// - **No entity for smart lists.** A `SavedSearch` already carries a name, a symbol, a colour, a
///   sidebar place, an order, and a soft delete. See the note on `SavedSearch.taskFilterData`.
/// - **No entity for checklist items.** They are never queried, linked, or listed on their own.
///
/// ### Why it is a version at all
/// For the reason spelled out on ``SchemaV3``: the version identifier is what the `.schema-version`
/// stamp beside the store is compared against, and a mismatch is what triggers the backup in
/// `PersistenceStack`. A schema change that did not bump the version would migrate real user data
/// with no backup taken.
public enum SchemaV7: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 7) }

    public static var models: [any PersistentModel.Type] {
        SchemaV6.models
    }
}

/// The eighth schema: the calendar module.
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
public enum SchemaV8: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 8) }

    public static var models: [any PersistentModel.Type] {
        SchemaV7.models + [
            CalendarSetRecord.self,
            EventTemplateRecord.self,
        ]
    }
}

/// The ninth schema: what a stretch of tracked time can be tied to.
///
/// **No new entities.** Two relationships and three attributes on ``TimeEntry`` — the people who
/// were there, the project it is billed to when derivation cannot reach one, the count of finished
/// focus blocks, and the pair of identifiers naming the calendar event this app wrote for it — plus
/// the two inverses those relationships need on ``Item``. Every one is optional or defaulted, so a
/// store opened under this version gains nullable columns and two empty join tables and keeps every
/// byte it had.
///
/// ### Why people are a relationship rather than tags
/// Because the question is *who*, and a tag cannot answer it. A `with-sarah` tag has no identity: it
/// does not follow a rename, it does not survive a merge of two duplicate contacts, it cannot be
/// clicked through to the person, and a report grouped by it lists strings rather than people. All
/// four of those already work for an `Item` of kind `person`, and standing rule R5 in `docs/18` asks
/// for proof that the existing shape cannot do the job — here the existing shape *is* the person,
/// and what was missing was a way to point at them.
///
/// ### Why `people` is its own relationship rather than reusing `item`
/// An entry filed against a person is time spent *on* them; an entry with a person present is time
/// spent *with* them. Preparing somebody's review and pairing with them for an afternoon are not the
/// same fact, and one list holding both makes neither answerable. See the note on
/// ``Item/attendedTimeEntries``.
///
/// ### Why the mirror identifiers live on the entry
/// The alternative was a side table mapping entries to events, and it buys nothing: the mapping is
/// one-to-one, it is written and read on exactly the paths that already hold the entry, and a
/// separate table would need its own answer to what happens when an entry is deleted. What it
/// *would* add is a second place for the two to disagree.
///
/// ### Why lightweight inference is still right
/// The same argument as every version since `SchemaV4`, and a weaker case than most: no new entity,
/// no rename, no type change, no value computed from old data. Nullable columns and additive
/// relationships are precisely what Core Data's inference exists for, and `RealStoreMigrationTests`
/// carries a store written before `TimeEntry` existed all the way here. ADR 0005 still reserves the
/// model-type freeze for the first change that cannot be inferred, and this is not it.
public enum SchemaV9: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 9) }

    public static var models: [any PersistentModel.Type] {
        SchemaV8.models
    }
}

/// The tenth schema: one nullable date saying the user put a synchronised item in the Inbox.
///
/// `Item.inboxedAt`, and nothing else. Additive, optional, defaulted to `nil` — a store opened under
/// this version gains a nullable column and keeps every byte it had.
///
/// ### Why the flood needed no data migration
/// Because the Inbox is a *query*, not a column. Imported reminders were never written into it; they
/// matched its definition — active, unparented, untagged, unfiled — the moment they were created.
/// Teaching ``Item/hasHome`` that a list in Apple Reminders is a home is therefore the whole fix, and
/// it takes effect on the next evaluation for every reminder already imported. Nothing is rewritten,
/// nothing is deleted, and no reminder or sync link is touched, which is the constraint that mattered
/// most: a library with four hundred imported reminders in its Inbox has four hundred fewer rows
/// there after this change and exactly the same rows in it.
///
/// This column exists only for the *other* direction — the user saying "put that one back", which is
/// the one thing a definition made of absences cannot express without breaking the link.
public enum SchemaV10: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 10) }

    public static var models: [any PersistentModel.Type] {
        SchemaV9.models
    }
}

/// The eleventh schema: a note's rich text.
///
/// One nullable `Data` column — `Item.noteDocumentData` — and nothing else. Additive, optional,
/// defaulted to `nil`, so a store opened under this version gains a nullable column and keeps every
/// byte it had.
///
/// ### Why there is no data migration, and why that is the safe direction
/// Because `nil` already means something true: *this note has not been opened since rich text
/// existed*, and its `body` is still the whole of it. Conversion happens on read, one note at a
/// time, through `NoteBodyImport` — which adopts structure only when re-projecting the result gives
/// back the original string character for character, and otherwise keeps the note as plain
/// paragraphs.
///
/// A custom stage would have to rewrite every note in the library at once, on the strength of a
/// parser that has never been run against *these* notes, at the one moment the user is least able to
/// judge the result and least able to undo it. ADR 0006's consequence 6 asks for the legacy read
/// path to stay until the conversion has been validated and a rollback window has passed, and a
/// nullable column that means "not yet" is what keeps that promise available. Nothing is rewritten
/// until the user opens a note and edits it.
///
/// ### Why it is a version at all
/// For the reason spelled out on ``SchemaV3``: the version identifier is what the `.schema-version`
/// stamp beside the store is compared against, and a mismatch is what triggers the backup in
/// `PersistenceStack`. A schema change that did not bump the version would migrate real user data
/// with no backup taken.
public enum SchemaV11: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 11) }

    public static var models: [any PersistentModel.Type] {
        SchemaV10.models
    }
}

/// The twelfth schema: a project becomes a workspace.
///
/// Eight new entities — `WorkflowStage`, `ProjectViewRecord`, `BugRecord`, `ItemComment`,
/// `ItemActivity`, `AutomationRule`, `CustomFieldDefinition`, `InboxNotification` — and nine
/// nullable or defaulted columns on `Item`. No rename, no type change, no column removed, so this
/// is still a lightweight stage that Core Data infers, and [ADR 0005]'s trigger for freezing the
/// model types is still not met.
///
/// Every new entity follows the CloudKit rules the store has kept since v1: every attribute
/// defaulted, no unique constraints, every to-one optional, every relationship declaring its
/// inverse, and no `.deny` rules. None of that is exercised yet — sync has not shipped for anything
/// — but the decision of record is that deferring sync must not make adopting it harder later, and
/// eight entities is exactly the scale at which retrofitting would hurt.
///
/// Numbered twelfth rather than eleventh because the rich-text column landed on `main` while
/// this work was in a worktree, and took eleven. Nothing about the change is different for it;
/// the two are independent additive stages that happen to have been written at the same time.
///
/// The one design note worth reading here rather than at the call site: **custom fields add no
/// storage.** `CustomFieldDefinition` names and types a key; the values live in `Item.userMetadata`,
/// which has been in the schema since v1. That is why renaming a field is a service operation that
/// moves values rather than a single write.
public enum SchemaV12: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 12) }

    public static var models: [any PersistentModel.Type] {
        SchemaV11.models + [
            WorkflowStage.self,
            ProjectViewRecord.self,
            BugRecord.self,
            ItemComment.self,
            ItemActivity.self,
            AutomationRule.self,
            CustomFieldDefinition.self,
            InboxNotification.self,
        ]
    }
}

/// The thirteenth schema: the day-relevance projection.
///
/// One defaulted date column — `Item.dayRelevanceKey` — and nothing else. Additive, non-optional
/// with a default, so a store opened under this version gains a column and keeps every byte it had.
///
/// ### Why the default is `.distantPast` and not `.distantFuture`
/// The column is a *fetch bound*: Today reads open work with `dayRelevanceKey < end-of-window`
/// instead of materialising every open item. `.distantFuture` would make every pre-existing row
/// match no window — dated work silently vanishing from Today the moment the store migrated, which
/// is the one failure this page must never have. `.distantPast` makes every pre-existing row match
/// *every* window: the fetch over-reads until each row's first save recomputes its key, and
/// `DayRelevanceBackfill` converges the whole library in one pass. A wrong key can only cost
/// milliseconds, never work.
///
/// ### Why lightweight inference is still right
/// The same argument as every version since `SchemaV4`, at its weakest scale: no new entity, no
/// rename, no type change, and the value is derived — recomputed on every save beside `dueSortKey`
/// — so nothing has to be computed *from old data at migration time*. ADR 0005 still reserves the
/// model-type freeze for the first change that cannot be inferred, and this is not it.
public enum SchemaV13: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 13) }

    public static var models: [any PersistentModel.Type] {
        SchemaV12.models
    }
}

/// The fourteenth schema: reusable records for people and things.
///
/// Adds one optional satellite table and one optional relationship from `Item`. Existing People
/// rows remain valid and are projected into Records until they acquire a profile through editing.
public enum SchemaV14: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 14) }

    public static var models: [any PersistentModel.Type] {
        SchemaV13.models + [RecordProfile.self]
    }
}

/// The fifteenth schema: every relationship has an inverse, because sync requires it.
///
/// Adds no entity and no column that stores anything new — six existing relationships gain
/// their inverse sides (`Item.contactLinks`, `.observationsAbout`, `.observationsSourced`,
/// `.relationshipsAsSubject`, `.relationshipsAsOther`, `.celebrations`, and
/// `Tag.timeEntries`), closing the gap between the model and the rule ``Item/timeEntries``
/// has stated since v2: CloudKit mirroring requires inverse relationships, and deferring
/// sync must not make adopting it harder later. A pre-sync audit found these six pairs
/// holding out; sync arrives behind this version, so the store crosses the boundary once.
///
/// Every inverse nullifies, deliberately. Before these existed, deleting an item never
/// touched the referencing rows — cleanup belongs to the repositories and the integrity
/// pass — and a schema bump made for sync must not quietly change what deletion means.
///
/// ### Why lightweight inference is still right
/// Inverse declarations reshape the relationship metadata, not the rows: no entity, no
/// rename, no type change, nothing computed from old data at migration time. ADR 0005's
/// freeze trigger remains unpulled.
public enum SchemaV15: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 15) }

    public static var models: [any PersistentModel.Type] {
        SchemaV14.models
    }
}

/// The sixteenth schema: every relationship is optional, because the mirroring
/// validator — not the documentation — is the authority on what CloudKit requires.
///
/// v15 closed the missing inverses and the constraint table called the model compliant;
/// the first real container open said otherwise, naming all twenty-nine to-many
/// relationships: *CloudKit integration requires that all relationships be optional*, and
/// a `[Tag]` with a default is still a non-optional relationship however defaulted its
/// value. The table had treated "optional **or** defaulted" — the attribute rule — as if
/// it covered relationships too. It does not, and docs/05 now says so.
///
/// The declarations changed in place — `[Tag]` to `[Tag]?` — precisely so that nothing
/// else did: names are what Core Data derives join tables and foreign keys from, and a
/// rename here would have silently emptied every many-to-many on migration. Relaxing
/// optionality changes metadata only; the rows, the join tables, and the values are
/// untouched, which is what keeps this lightweight.
public enum SchemaV16: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 16) }

    public static var models: [any PersistentModel.Type] {
        SchemaV15.models
    }
}

/// The seventeenth schema: the working day belongs to the person, not to the device.
///
/// Adds one table, `WorkdaySettingsRecord`, with no relationships and every attribute defaulted.
///
/// ### Why a table and not a preference
/// Working hours already existed — on ``CalendarSetRecord``, editable only from the Mac's calendar
/// set editor — and which set is *active* is a per-device `UserDefaults` key. So a phone with no set
/// chosen on that phone resolved to `WorkingHours.standard` and measured "how much of today is free"
/// against nine-to-five, Monday-to-Friday, which nobody had said and nobody could see. The fix is an
/// app-level default that syncs, with a set continuing to override it while one is active. A
/// preference would have reproduced the bug on the next device.
///
/// ### Why lightweight inference is still right
/// The same argument as every version since `SchemaV4`: a new entity, no rename, no type change, and
/// nothing computed from old data at migration time. A store opened under this version gains an
/// empty table, and an empty table reads as "nobody has said", which is exactly what was true before
/// the migration ran. ADR 0005's model-type freeze stays unpulled.
public enum SchemaV17: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 17) }

    public static var models: [any PersistentModel.Type] {
        SchemaV16.models + [WorkdaySettingsRecord.self]
    }
}

/// The eighteenth schema: somebody can be recorded before their name is known.
///
/// Adds one attribute, `PersonProfile.hasStatedName`, defaulted to `true`.
///
/// ### Why this is lightweight, and why the default is that way round
/// A new non-optional attribute with a default is the textbook additive change: Core Data adds a
/// column and writes the default into every existing row, touching no relationship and no join
/// table. Nothing is computed at migration time and nothing can fail part-way.
///
/// The default has to be `true`, and not because it is the commoner value. Every record that existed
/// before this version was created through a path that *required* a name — the empty string was a
/// validation failure — so "this person has a stated name" is not an assumption about old data, it
/// is a fact about it. Defaulting to `false` would put the entire existing library into the "to fill
/// in" list on first launch, asking the user to supply names they had already supplied.
public enum SchemaV18: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(0, 0, 18) }

    public static var models: [any PersistentModel.Type] {
        SchemaV17.models
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
        [SchemaV18.self]
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
    public static var versioned: any VersionedSchema.Type { SchemaV18.self }

    public static var schema: Schema { Schema(versionedSchema: SchemaV18.self) }

    /// Human-readable version, for diagnostics and export archives.
    public static var versionString: String {
        // Read from `versioned` rather than named again, so a new version cannot leave the archives
        // and the diagnostics claiming the previous one.
        let version = versioned.versionIdentifier
        return "\(version.major).\(version.minor).\(version.patch)"
    }
}
