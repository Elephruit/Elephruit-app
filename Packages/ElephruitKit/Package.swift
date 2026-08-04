// swift-tools-version: 6.2
import PackageDescription

/// Every module of Elephruit lives in this one package.
///
/// One package with many targets — rather than many packages — because module
/// boundaries are then enforced by the compiler while the dependency graph stays
/// visible in a single file, and `swift test` runs the whole suite without signing,
/// a simulator, or an Xcode scheme.
let package = Package(
    name: "ElephruitKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // A single product containing every module. The app target links this once
        // and imports whichever modules it needs.
        .library(
            name: "ElephruitKit",
            targets: [
                "ElephruitCore",
                "ElephruitModel",
                "ElephruitPersistence",
                "ElephruitSearch",
                "ElephruitDesign",
                "ElephruitTransfer",
                "ElephruitIntegrations",
                "ElephruitFeaturesCore",
                "ElephruitFeatures",
            ]
        ),
        // The same package as the iPhone sees it: everything except `ElephruitFeatures`,
        // whose views are AppKit-shaped (three-column windows, NSTextView editors, menu
        // bar extras) and are not asked to compile for a platform they cannot mean
        // anything on. Building this product for an iOS destination is the compile-time
        // proof that no AppKit leak has crept below the view layer.
        .library(
            name: "ElephruitMobileKit",
            targets: [
                "ElephruitCore",
                "ElephruitModel",
                "ElephruitPersistence",
                "ElephruitSearch",
                "ElephruitTransfer",
                "ElephruitIntegrations",
                "ElephruitDesign",
                "ElephruitFeaturesCore",
            ]
        ),
    ],
    targets: [
        // MARK: - Foundation

        /// Pure Swift domain vocabulary. No SwiftData, no SwiftUI, no Foundation
        /// beyond value types. Everything else depends on this; it depends on nothing.
        .target(name: "ElephruitCore", swiftSettings: .strict),

        /// SwiftData entities and the versioned schema.
        .target(name: "ElephruitModel", dependencies: ["ElephruitCore"], swiftSettings: .strict),

        /// Container bootstrap, migrations, repositories, predicate builders.
        .target(
            name: "ElephruitPersistence",
            dependencies: ["ElephruitCore", "ElephruitModel"],
            swiftSettings: .strict
        ),

        // MARK: - Services

        /// Query grammar, parser, and the search engine behind a protocol.
        .target(
            name: "ElephruitSearch",
            dependencies: ["ElephruitCore", "ElephruitModel", "ElephruitPersistence"],
            swiftSettings: .strict
        ),

        /// Archive and Markdown codecs, importer pipeline.
        .target(
            name: "ElephruitTransfer",
            dependencies: ["ElephruitCore", "ElephruitModel", "ElephruitPersistence"],
            swiftSettings: .strict
        ),

        /// EventKit, Contacts, notifications, on-device enrichment — each behind a
        /// protocol with an inert default so the app never depends on a permission.
        .target(name: "ElephruitIntegrations", dependencies: ["ElephruitCore"], swiftSettings: .strict),

        // MARK: - Interface

        /// Design tokens and reusable components. Knows `ItemKind`; knows nothing else
        /// about the domain.
        .target(name: "ElephruitDesign", dependencies: ["ElephruitCore"], swiftSettings: .strict),

        /// The platform-independent half of the feature layer: the composition root
        /// (`AppServices`), navigation state, and the @Observable models behind Today,
        /// Capture, Calendar, Records, Search, and Time. No AppKit, no UIKit, and no
        /// views — which is what lets one set of models sit behind two very different
        /// shells without either shell compromising the other.
        .target(
            name: "ElephruitFeaturesCore",
            dependencies: [
                "ElephruitCore",
                "ElephruitModel",
                "ElephruitPersistence",
                "ElephruitSearch",
                "ElephruitTransfer",
                "ElephruitDesign",
                "ElephruitIntegrations",
            ],
            swiftSettings: .strict
        ),

        /// Feature modules: one folder per feature, each a view plus an @Observable model.
        ///
        /// macOS-only. The models these views observe live in `ElephruitFeaturesCore`,
        /// re-exported here so the split is invisible to every existing view file.
        .target(
            name: "ElephruitFeatures",
            dependencies: [
                "ElephruitCore",
                "ElephruitModel",
                "ElephruitPersistence",
                "ElephruitSearch",
                "ElephruitTransfer",
                "ElephruitDesign",
                "ElephruitIntegrations",
                "ElephruitFeaturesCore",
            ],
            swiftSettings: .strict
        ),

        // MARK: - Tests

        .testTarget(name: "ElephruitCoreTests", dependencies: ["ElephruitCore"], swiftSettings: .strict),
        // `ElephruitIntegrations` is here for `FixtureRemindersProvider` — the in-memory Reminders
        // store. It is what makes "no automated test touches the developer's real Reminders
        // database" true by construction: the fake is the only implementation these tests can
        // reach, because they never import EventKit and never construct the adapter that does.
        .testTarget(
            name: "ElephruitPersistenceTests",
            dependencies: [
                "ElephruitPersistence", "ElephruitModel", "ElephruitCore", "ElephruitDesign",
                "ElephruitIntegrations",
            ],
            swiftSettings: .strict
        ),
        .testTarget(
            name: "ElephruitSearchTests",
            dependencies: ["ElephruitSearch", "ElephruitPersistence", "ElephruitModel", "ElephruitCore"],
            swiftSettings: .strict
        ),
        // Benchmarks. Excluded from the default plan and gated on ELEPHRUIT_BENCHMARKS=1, so an
        // ordinary `swift test` never runs them and a busy machine never reddens a build.
        .testTarget(
            name: "ElephruitBenchmarks",
            dependencies: [
                "ElephruitCore", "ElephruitModel", "ElephruitPersistence", "ElephruitSearch",
                "ElephruitFeatures", "ElephruitIntegrations",
            ],
            swiftSettings: .strict
        ),
        .testTarget(
            name: "ElephruitFeaturesTests",
            dependencies: [
                "ElephruitFeatures", "ElephruitFeaturesCore", "ElephruitPersistence",
                "ElephruitModel", "ElephruitCore", "ElephruitDesign", "ElephruitIntegrations",
            ],
            swiftSettings: .strict
        ),
        /// The system adapters. A target of its own rather than folded into `ElephruitCoreTests`,
        /// because the write-safety checks need to *import* the adapters to exercise their inert
        /// defaults — the calendar's equivalent only scans the source and so did not.
        .testTarget(
            name: "ElephruitIntegrationsTests",
            dependencies: ["ElephruitIntegrations", "ElephruitCore"],
            swiftSettings: .strict
        ),
        .testTarget(
            name: "ElephruitTransferTests",
            dependencies: ["ElephruitTransfer", "ElephruitPersistence", "ElephruitModel", "ElephruitCore"],
            swiftSettings: .strict
        ),
    ]
)

extension [SwiftSetting] {
    /// Warnings are build failures. Applied to every target so the rule cannot be
    /// quietly skipped for one of them.
    ///
    /// Swift 6 language mode — which brings complete concurrency checking — comes from
    /// the tools version rather than a flag.
    ///
    /// `.strictMemorySafety()` is deliberately *not* enabled: it flags ordinary
    /// Foundation calls that take `CVarArg` (`String(format:)` among them) as unsafe,
    /// which produces noise rather than safety in a codebase that contains no pointer
    /// arithmetic, no manual memory management, and no C interop.
    static var strict: [SwiftSetting] {
        [.treatAllWarnings(as: .error)]
    }
}
