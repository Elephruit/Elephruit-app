import OSLog

/// Structured diagnostics.
///
/// `OSLog` only — never a file, never a network call, never a third-party SDK. See
/// `docs/06-privacy-and-entitlements.md`.
///
/// **User content never appears in a log.** Log statements carry identifiers, counts,
/// durations, and enum cases. Where a string genuinely must be logged it is annotated
/// `privacy: .private` at the call site, and a test scans the sources for
/// interpolations that are not.
public enum Diagnostics {
    /// Reverse-DNS subsystem, matching the bundle identifier.
    public static let subsystem = "com.elephruit.Elephruit"

    /// Store lifecycle: opening, migrating, saving, integrity passes.
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")

    /// Index construction, query execution, Spotlight donation.
    public static let search = Logger(subsystem: subsystem, category: "search")

    /// Import and export runs.
    public static let transfer = Logger(subsystem: subsystem, category: "transfer")

    /// Window and scene lifecycle, command routing.
    public static let shell = Logger(subsystem: subsystem, category: "shell")

    /// Feature-level events worth tracing when something misbehaves.
    public static let features = Logger(subsystem: subsystem, category: "features")

    /// Permission-gated system integrations.
    public static let integrations = Logger(subsystem: subsystem, category: "integrations")

    /// Signposts for the performance targets in `docs/01-product-definition.md`.
    public static let performance = OSSignposter(
        logger: Logger(subsystem: subsystem, category: "performance")
    )
}
