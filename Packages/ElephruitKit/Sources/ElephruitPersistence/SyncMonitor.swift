import CloudKit
import CoreData
import Foundation
import Observation

/// Listens to the mirroring machinery and keeps ``SyncStatus`` truthful.
///
/// SwiftData's CloudKit mirroring runs inside an `NSPersistentCloudKitContainer` the
/// framework owns and does not expose — but the container announces every setup, import,
/// and export through `eventChangedNotification`, and a name-based observation needs no
/// object. This type is that observation, folded into the one enum the sidebar reads.
///
/// ### Why the state machine is its own method
/// `ingest(_:)` takes a plain value describing an event, so a test can drive the whole
/// machine — syncing, idle, offline, failed, and back — without CloudKit, an account, or
/// a network. The notification handler's only job is translation.
@Observable
@MainActor
public final class SyncMonitor {
    /// One mirroring event, reduced to what the status line needs.
    public struct Event: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case setup
            case importRecords
            case exportRecords
        }

        public var kind: Kind
        public var ended: Date?
        public var succeeded: Bool
        /// `CKError.Code.rawValue` when the failure was CloudKit's; nil otherwise.
        public var cloudKitErrorCode: Int?
        public var failureDescription: String?

        public init(
            kind: Kind,
            ended: Date?,
            succeeded: Bool,
            cloudKitErrorCode: Int? = nil,
            failureDescription: String? = nil
        ) {
            self.kind = kind
            self.ended = ended
            self.succeeded = succeeded
            self.cloudKitErrorCode = cloudKitErrorCode
            self.failureDescription = failureDescription
        }
    }

    public private(set) var status: SyncStatus

    /// Runs after a completed import — the moment another device's changes are in the
    /// store and everything derived from it is stale. The service graph hangs its
    /// refresh pass here.
    @ObservationIgnored public var onImportCompleted: (@MainActor () -> Void)?

    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    public init(enabled: Bool) {
        status = enabled ? .idle(lastSyncedAt: nil) : .disabled
        guard enabled else { return }

        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let raw = notification.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                ] as? NSPersistentCloudKitContainer.Event
            else { return }

            let kind: Event.Kind? =
                switch raw.type {
                case .setup: .setup
                case .import: .importRecords
                case .export: .exportRecords
                @unknown default: nil
                }
            guard let kind else { return }

            let event = Event(
                kind: kind,
                ended: raw.endDate,
                succeeded: raw.succeeded,
                cloudKitErrorCode: (raw.error as? CKError)?.errorCode,
                failureDescription: raw.error?.localizedDescription
            )
            // The queue is `.main`, so the hop is an assertion rather than a dispatch;
            // only the reduced Sendable value crosses into isolation.
            MainActor.assumeIsolated {
                self?.ingest(event)
            }
        }
    }

    /// Folds one event into the status. Public so tests drive the machine directly.
    public func ingest(_ event: Event) {
        guard status != .disabled else { return }

        // An event with no end date has just started.
        guard let ended = event.ended else {
            status = .syncing
            return
        }

        if event.succeeded {
            status = .idle(lastSyncedAt: ended)
            if event.kind == .importRecords {
                onImportCompleted?()
            }
            return
        }

        // CloudKit says which failures are the network's fault; those are a state, not a
        // problem, and the app says "offline" rather than crying wolf.
        let networkCodes: Set<Int> = [
            CKError.networkUnavailable.rawValue,
            CKError.networkFailure.rawValue,
            CKError.serviceUnavailable.rawValue,
            CKError.requestRateLimited.rawValue,
        ]
        if let code = event.cloudKitErrorCode, networkCodes.contains(code) {
            status = .offline
            return
        }

        // Account trouble reads as a failure the user can act on — the description
        // carries CloudKit's own words.
        status = .failed(reason: event.failureDescription ?? "Sync failed")
    }
}

/// Where the sync switch is remembered.
///
/// One key, both platforms, read once at boot — the container decision is made before
/// the first fetch, so flipping it applies at the next launch and the toggle says so.
public enum SyncSetting {
    public static let enabledKey = "sync.enabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }
}
