import ElephruitCore
import ElephruitPersistence
import Foundation
import Testing

/// A normalised benchmark harness.
///
/// ### Why not just measure and assert
/// Wall-clock budgets make builds flaky. The same code passes on an idle machine and fails on a busy
/// one, and once a suite has cried wolf twice nobody trusts it again. But dropping timing altogether
/// gives up the only signal that catches a real slowdown.
///
/// So: measure, then divide by what the *host* is currently capable of. A calibration workload runs
/// first and yields a `hostFactor`; budgets scale by it, so a machine running at half speed gets
/// twice the budget rather than a red build. A separate absolute ceiling still catches genuine
/// regressions on any host.
///
/// Both figures are always reported. A normalised number that stays flat while the raw number climbs
/// is a real slowdown that calibration is absorbing, and printing only the normalised one would hide
/// exactly the thing worth knowing.
///
/// ### Opting in
/// This target is excluded from the default test plan and runs only when `ELEPHRUIT_BENCHMARKS=1` is
/// set. An ordinary `swift test` never executes it.
public enum Benchmark {
    /// Whether benchmarks were asked for.
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ELEPHRUIT_BENCHMARKS"] == "1"
    }

    /// How much slower a measurement may be than its budget before failing outright, regardless of
    /// calibration. Catches a genuine regression that a slow host would otherwise excuse.
    public static let absoluteCeilingMultiplier: Double = 4.0

    // MARK: - Calibration

    /// A deterministic workload whose duration characterises the host.
    ///
    /// Deliberately mixed: integer work, allocation, and string hashing, because a machine can be
    /// fast at one and slow at another and a single-dimension probe would mis-scale.
    public static func calibrationWorkload() -> Double {
        var accumulator = 0.0
        var strings: [String] = []
        strings.reserveCapacity(2_000)

        for index in 0..<200_000 {
            accumulator += Double(index % 97) * 1.000_001
        }
        for index in 0..<2_000 {
            strings.append("calibration-\(index)-\(index % 13)")
        }
        var hash = 0
        for value in strings {
            hash ^= value.hashValue
        }

        return accumulator + Double(hash % 2)
    }

    /// The host's calibration time, measured once per process.
    ///
    /// Run three times and take the median: the first is warm-up, and a single sample on a machine
    /// that briefly descheduled would skew every budget in the run.
    public static let hostCalibrationSeconds: Double = {
        var samples: [Double] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            _ = calibrationWorkload()
            samples.append((ContinuousClock.now - start).seconds)
        }
        return samples.sorted()[1]
    }()

    /// How much slower this host is than the reference. `1.0` on the reference machine.
    public static var hostFactor: Double {
        guard let reference = ReferenceMachine.load(), reference.calibrationSeconds > 0 else {
            return 1.0
        }
        return max(1.0, hostCalibrationSeconds / reference.calibrationSeconds)
    }

    // MARK: - Measurement

    public struct Measurement: Sendable {
        public let name: String
        public let rawSeconds: Double
        public let normalisedSeconds: Double
        public let budgetSeconds: Double
        public let hostFactor: Double

        public var passesNormalised: Bool { normalisedSeconds <= budgetSeconds }
        public var passesAbsolute: Bool {
            rawSeconds <= budgetSeconds * Benchmark.absoluteCeilingMultiplier
        }
        public var passes: Bool { passesNormalised && passesAbsolute }

        /// Both figures, always. See the note on the harness.
        public var report: String {
            String(
                format: "%-28@ normalised %7.2f ms  (budget %6.2f)   raw %7.2f ms   hostFactor %.2f",
                name as NSString,
                normalisedSeconds * 1_000,
                budgetSeconds * 1_000,
                rawSeconds * 1_000,
                hostFactor
            )
        }
    }

    /// Runs `body` `iterations` times and reports the median against `budget`.
    ///
    /// Median rather than mean: one descheduled iteration should not decide the result, and a mean
    /// lets it.
    @discardableResult
    public static func measure(
        _ name: String,
        budget: Duration,
        iterations: Int = 5,
        _ body: () throws -> Void
    ) rethrows -> Measurement {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = ContinuousClock.now
            try body()
            samples.append((ContinuousClock.now - start).seconds)
        }

        let raw = samples.sorted()[samples.count / 2]
        let factor = hostFactor

        let measurement = Measurement(
            name: name,
            rawSeconds: raw,
            normalisedSeconds: raw / factor,
            budgetSeconds: budget.seconds,
            hostFactor: factor
        )

        print(measurement.report)
        return measurement
    }

    /// The `async` form.
    ///
    /// The closure is `@MainActor`: every async thing measured here is main-actor work — a repository
    /// read, a counts refresh — and marking it so avoids sending a non-`Sendable` closure across an
    /// isolation boundary just to time it.
    @discardableResult
    @MainActor
    public static func measure(
        _ name: String,
        budget: Duration,
        iterations: Int = 5,
        _ body: @MainActor () async throws -> Void
    ) async rethrows -> Measurement {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = ContinuousClock.now
            try await body()
            samples.append((ContinuousClock.now - start).seconds)
        }

        let raw = samples.sorted()[samples.count / 2]
        let factor = hostFactor

        let measurement = Measurement(
            name: name,
            rawSeconds: raw,
            normalisedSeconds: raw / factor,
            budgetSeconds: budget.seconds,
            hostFactor: factor
        )

        print(measurement.report)
        return measurement
    }

    /// Runs `body` once per input and reports a percentile rather than the median.
    ///
    /// Interactive budgets are stated at p95 on purpose. A median keystroke latency says nothing
    /// about whether typing *feels* smooth — one query in twenty taking half a second is exactly
    /// what makes a search field feel unreliable, and a median hides it completely.
    @discardableResult
    @MainActor
    public static func measurePercentile<Input>(
        _ name: String,
        budget: Duration,
        percentile: Double = 0.95,
        inputs: [Input],
        _ body: @MainActor (Input) async throws -> Void
    ) async rethrows -> Measurement {
        var samples: [Double] = []
        samples.reserveCapacity(inputs.count)

        for input in inputs {
            let start = ContinuousClock.now
            try await body(input)
            samples.append((ContinuousClock.now - start).seconds)
        }

        let sorted = samples.sorted()
        // Nearest-rank: the smallest sample at or above the percentile, which never interpolates a
        // value that was not actually observed.
        let rank = max(1, Int((percentile * Double(sorted.count)).rounded(.up)))
        let raw = sorted[min(rank - 1, sorted.count - 1)]
        let factor = hostFactor

        let measurement = Measurement(
            name: name,
            rawSeconds: raw,
            normalisedSeconds: raw / factor,
            budgetSeconds: budget.seconds,
            hostFactor: factor
        )

        print(measurement.report)
        print(String(
            format: "  └ %d samples · min %.2f ms · median %.2f ms · max %.2f ms",
            sorted.count,
            (sorted.first ?? 0) * 1_000,
            sorted[sorted.count / 2] * 1_000,
            (sorted.last ?? 0) * 1_000
        ))
        return measurement
    }
}

extension Duration {
    /// Seconds as a `Double`, for arithmetic against a budget.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// The machine the published budgets were set on.
///
/// Committed, so "under 5 ms" means something specific rather than "fast on whatever I had open".
public struct ReferenceMachine: Codable, Sendable {
    public var modelIdentifier: String
    public var coreCount: Int
    public var operatingSystem: String
    public var calibrationSeconds: Double
    public var recordedAt: String

    /// Reads `Benchmarks/reference.json`, walking up from this file.
    public static func load() -> ReferenceMachine? {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()

        for _ in 0..<8 {
            let candidate = directory
                .appending(path: "Benchmarks", directoryHint: .isDirectory)
                .appending(path: "reference.json", directoryHint: .notDirectory)

            if let data = try? Data(contentsOf: candidate),
               let machine = try? JSONDecoder().decode(ReferenceMachine.self, from: data) {
                return machine
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// This machine, for regenerating the reference file.
    public static func current(calibrationSeconds: Double) -> ReferenceMachine {
        var model = "unknown"
        var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [UInt8](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 {
                // sysctl returns a null-terminated string; drop the terminator before decoding.
                let bytes = buffer.prefix { $0 != 0 }
                model = String(decoding: bytes, as: UTF8.self)
            }
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion

        return ReferenceMachine(
            modelIdentifier: model,
            coreCount: ProcessInfo.processInfo.processorCount,
            operatingSystem: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            calibrationSeconds: calibrationSeconds,
            recordedAt: Date().formatted(.iso8601)
        )
    }
}

// MARK: - Workspace

/// Where benchmarks put the stores and indexes they build.
///
/// ### The leak this replaces
/// Every benchmark used to call `StoreLocation.temporary()`, which mints a fresh UUID directory, and
/// none of them deleted it afterwards. A search index over a large corpus is hundreds of megabytes
/// and a 200,000-entry store is over a hundred; across a few dozen runs that had quietly accumulated
/// **4.1 GB** in the user's temporary directory. Nothing failed, nothing warned, and the only symptom
/// would have been a disk filling up for no visible reason.
///
/// Everything now lives under one root that is **wiped when a process first touches it**. Disk is
/// therefore bounded by a single run rather than by how many times anyone has ever run benchmarks.
///
/// Wiping on start rather than on finish is deliberate: swift-testing has no suite-level teardown
/// that survives a cancelled or crashed run, and a cleanup that only happens on the happy path is
/// exactly how this got to four gigabytes. Wiping on start cannot be skipped.
@MainActor
public enum BenchmarkWorkspace {
    /// The root, wiped once per process on first access.
    public static let root: URL = {
        let url = URL.temporaryDirectory.appending(path: "ElephruitBenchmarks", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A store location inside the workspace.
    public static func storeLocation(named name: String) -> StoreLocation {
        let base = root.appending(path: name, directoryHint: .isDirectory)
        return StoreLocation(
            root: base.appending(path: "Library", directoryHint: .isDirectory),
            cachesRoot: base.appending(path: "Caches", directoryHint: .isDirectory)
        )
    }

    /// A search index file inside the workspace.
    public static func indexURL(named name: String) -> URL {
        root.appending(path: "\(name).sqlite", directoryHint: .notDirectory)
    }

    /// Bytes currently held, so a run can report what it left behind.
    public static func bytesUsed() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    public static func reportUsage() {
        let megabytes = Double(bytesUsed()) / 1_048_576
        print(String(format: "  [workspace] %.0f MB under %@", megabytes, root.path as NSString))
    }
}
