import Foundation

/// Everything that can go wrong in a way the user needs to know about.
///
/// Two rules govern this type:
///
/// 1. **Every case is recoverable.** There is no `fatalError` anywhere in the app for
///    a condition representable here. A failure the user cannot act on is a bug, not
///    an error case.
/// 2. **Every case carries a recovery.** ``AppError/recovery`` returns the actions the
///    UI should offer, so an error dialogue is never a dead end with only "OK".
public enum AppError: Error, Sendable, Hashable {
    /// The data store could not be opened. The app runs in a degraded state that can
    /// still export and reveal files.
    case storeUnavailable(underlying: String)

    /// A schema migration failed. A pre-migration backup exists at `backupPath`.
    case migrationFailed(fromVersion: String, toVersion: String, backupPath: String?)

    /// An item failed validation and was not saved.
    case validation(ValidationFailure)

    /// An item was expected to exist and did not.
    case itemNotFound(id: UUID)

    /// An insert was attempted with an identifier already present in the store.
    case duplicateIdentifier(id: UUID)

    /// The sandbox refused access to a file the user chose, or a bookmark went stale.
    case fileAccessDenied(path: String)

    /// A referenced external file could not be found at its last known location.
    case externalFileMissing(lastKnownPath: String)

    /// An attachment's metadata exists but its bytes do not.
    case attachmentBytesMissing(attachmentID: UUID, expectedPath: String)

    /// A search query could not be parsed.
    case invalidQuery(reason: String)

    /// Import failed before writing anything. The store is untouched.
    case importFailed(format: String, reason: String)

    /// Export failed. Any partial output has been removed.
    case exportFailed(reason: String)

    /// A write to disk failed.
    case writeFailed(path: String, reason: String)

    /// A timer was asked to start while another was already running.
    ///
    /// Refusing rather than silently stopping the first one: the running timer is a record of what
    /// the user is doing, and quietly ending it is exactly the kind of unrequested consequential
    /// decision the app does not make. The caller that means "switch" says so.
    case timerAlreadyRunning(description: String)
}

// MARK: - Presentation

extension AppError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            "Elephruit could not open your library."
        case .migrationFailed:
            "Your library could not be upgraded to this version."
        case .validation(let failure):
            failure.summary
        case .itemNotFound:
            "That item no longer exists."
        case .duplicateIdentifier:
            "An item with the same identifier is already in your library."
        case .fileAccessDenied(let path):
            "Elephruit does not have permission to open “\(Self.displayName(forPath: path))”."
        case .externalFileMissing(let path):
            "“\(Self.displayName(forPath: path))” has moved or been renamed."
        case .attachmentBytesMissing:
            "This attachment's file is missing."
        case .invalidQuery:
            "That search could not be understood."
        case .importFailed(let format, _):
            "The \(format) import did not complete."
        case .exportFailed:
            "The export did not complete."
        case .writeFailed(let path, _):
            "Elephruit could not save to “\(Self.displayName(forPath: path))”."
        case .timerAlreadyRunning:
            "A timer is already running."
        }
    }

    public var failureReason: String? {
        switch self {
        case .storeUnavailable(let underlying):
            underlying
        case .migrationFailed(let from, let to, _):
            "Upgrading from schema \(from) to \(to) did not finish."
        case .validation(let failure):
            failure.detail
        case .itemNotFound:
            "It may have been deleted in another window or on another device."
        case .duplicateIdentifier:
            "Two items cannot share an identifier."
        case .fileAccessDenied:
            "Files must be opened through the Open panel so that macOS can grant access."
        case .externalFileMissing:
            "Elephruit stores a reference to this file rather than a copy of it."
        case .attachmentBytesMissing(_, let expectedPath):
            "Expected to find it at \(expectedPath)."
        case .invalidQuery(let reason):
            reason
        case .importFailed(_, let reason):
            reason
        case .exportFailed(let reason):
            reason
        case .writeFailed(_, let reason):
            reason
        case .timerAlreadyRunning(let description):
            description.isEmpty
                ? "Stop it before starting another."
                : "“\(description)” is being timed. Stop it before starting another."
        }
    }

    public var recoverySuggestion: String? {
        recovery.first?.title
    }

    /// One line, for a log or a diagnostic surface.
    ///
    /// Deliberately built from the same two strings the user would see, so a log line and an alert
    /// can never describe the same failure differently.
    public var summary: String {
        let description = errorDescription ?? "Something went wrong."
        guard let reason = failureReason, !reason.isEmpty else { return description }
        return "\(description) \(reason)"
    }
}

// MARK: - Recovery

extension AppError {
    /// What the user can do about it. The UI renders these as buttons, in order, with
    /// the first as the default.
    ///
    /// Recovery is part of the error's definition rather than decided at the call site,
    /// so the same failure always offers the same way out.
    public var recovery: [RecoveryOption] {
        switch self {
        case .storeUnavailable:
            [.retry, .revealLibraryInFinder, .quit]
        case .migrationFailed(_, _, let backupPath):
            backupPath == nil ? [.retry, .quit] : [.retry, .revealBackupInFinder, .quit]
        case .validation:
            [.dismiss]
        case .itemNotFound:
            [.dismiss]
        case .duplicateIdentifier:
            [.keepBoth, .skip, .dismiss]
        case .fileAccessDenied:
            [.chooseFile, .dismiss]
        case .externalFileMissing:
            [.locateFile, .removeReference, .dismiss]
        case .attachmentBytesMissing:
            [.locateFile, .removeReference, .dismiss]
        case .invalidQuery:
            [.dismiss]
        case .importFailed:
            [.dismiss]
        case .exportFailed:
            [.retry, .chooseFile, .dismiss]
        case .writeFailed:
            [.retry, .chooseFile, .dismiss]
        case .timerAlreadyRunning:
            // No "stop it and start mine" here. That is a different action with a different
            // consequence, and offering it inside an error dialogue would make stopping a timer
            // something you do by dismissing a message.
            [.dismiss]
        }
    }

    /// Whether the app can carry on normally after this. `false` means the shell shows
    /// a dedicated failure state instead of the usual interface.
    public var isRecoverableInPlace: Bool {
        switch self {
        case .storeUnavailable, .migrationFailed: false
        default: true
        }
    }

    private static func displayName(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// An action offered to the user in response to an ``AppError``.
public enum RecoveryOption: Sendable, Hashable, CaseIterable {
    case retry
    case dismiss
    case quit
    case revealLibraryInFinder
    case revealBackupInFinder
    case chooseFile
    case locateFile
    case removeReference
    case keepBoth
    case skip

    public var title: String {
        switch self {
        case .retry: "Try Again"
        case .dismiss: "OK"
        case .quit: "Quit Elephruit"
        case .revealLibraryInFinder: "Reveal Library in Finder"
        case .revealBackupInFinder: "Reveal Backup in Finder"
        case .chooseFile: "Choose Location…"
        case .locateFile: "Locate…"
        case .removeReference: "Remove Reference"
        case .keepBoth: "Keep Both"
        case .skip: "Skip"
        }
    }

    /// Whether choosing this option destroys something. Rendered with the destructive
    /// role and never made the default.
    public var isDestructive: Bool {
        self == .removeReference
    }
}

// MARK: - Validation

/// Why an item was rejected.
///
/// Validation failures name the field, so the UI can move focus to it rather than
/// leaving the user to guess.
public struct ValidationFailure: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// A field carries a value that its kind does not support — a `dueAt` on a note.
        case fieldNotSupportedByKind(field: String, kind: ItemKind)

        /// `status == .completed` without a `completedAt`, or the reverse.
        case statusDateMismatch

        /// A kind that does not support status was given one.
        case statusNotSupportedByKind(kind: ItemKind)

        /// The proposed parent may not contain this kind of child.
        case invalidContainment(parentKind: ItemKind, childKind: ItemKind)

        /// The proposed parent is the item itself, or one of its descendants.
        case containmentCycle

        /// A tag name normalised to nothing usable.
        case emptyTagName

        /// A person's name normalised to nothing usable.
        ///
        /// Separate from ``emptyTagName`` because the remedy differs: a tag can be dropped, whereas a
        /// person referred to by an unusable name is somebody the user was trying to record and the
        /// interface has to say so rather than quietly creating a nameless record.
        case emptyPersonName

        /// A date range where the end precedes the start.
        case invalidDateRange(startField: String, endField: String)
    }

    public let reason: Reason

    /// The field the UI should focus, if the failure has one.
    public let field: String?

    public init(reason: Reason, field: String? = nil) {
        self.reason = reason
        self.field = field
    }

    var summary: String {
        switch reason {
        case .fieldNotSupportedByKind(_, let kind):
            "A \(kind.displayName.lowercased()) cannot hold that value."
        case .statusDateMismatch:
            "The completion state and completion date disagree."
        case .statusNotSupportedByKind(let kind):
            "A \(kind.displayName.lowercased()) cannot be completed."
        case .invalidContainment:
            "That item cannot go there."
        case .containmentCycle:
            "An item cannot contain itself."
        case .emptyTagName:
            "A tag needs a name."
        case .emptyPersonName:
            "A person needs a name."
        case .invalidDateRange:
            "Those dates are the wrong way round."
        }
    }

    var detail: String {
        switch reason {
        case .fieldNotSupportedByKind(let field, let kind):
            "“\(field)” does not apply to a \(kind.displayName.lowercased())."
        case .statusDateMismatch:
            "A completed item must have a completion date, and only a completed item may have one."
        case .statusNotSupportedByKind(let kind):
            "\(kind.pluralDisplayName) do not have a completion state."
        case .invalidContainment(let parentKind, let childKind):
            "A \(parentKind.displayName.lowercased()) cannot contain a \(childKind.displayName.lowercased())."
        case .containmentCycle:
            "The chosen parent is the item itself or one of the items inside it."
        case .emptyTagName:
            "Tag names must contain at least one letter or number."
        case .emptyPersonName:
            "A person's name must contain at least one letter or number."
        case .invalidDateRange(let startField, let endField):
            "“\(endField)” falls before “\(startField)”."
        }
    }
}
