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
    platforms: [.macOS(.v26)],
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
                "ElephruitFeatures",
            ]
        )
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

        /// Feature modules: one folder per feature, each a view plus an @Observable model.
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
            ],
            swiftSettings: .strict
        ),

        // MARK: - Tests

        .testTarget(name: "ElephruitCoreTests", dependencies: ["ElephruitCore"], swiftSettings: .strict),
        .testTarget(
            name: "ElephruitPersistenceTests",
            dependencies: ["ElephruitPersistence", "ElephruitModel", "ElephruitCore", "ElephruitDesign"],
            swiftSettings: .strict
        ),
        .testTarget(
            name: "ElephruitSearchTests",
            dependencies: ["ElephruitSearch", "ElephruitPersistence", "ElephruitModel", "ElephruitCore"],
            swiftSettings: .strict
        ),
        .testTarget(
            name: "ElephruitFeaturesTests",
            dependencies: ["ElephruitFeatures", "ElephruitPersistence", "ElephruitModel", "ElephruitCore"],
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
