import ElephruitCore
import Foundation

/// The reproducibility context available without asking the reporter to type it.
///
/// Captured when the bug is filed, not when it is later viewed: an OS or app update between those
/// moments must not rewrite which build actually showed the problem.
struct BugReportDeviceContext: Sendable, Equatable {
    let environment: String
    let affectedVersion: String

    var facts: BugFacts {
        BugFacts(environment: environment, affectedVersion: affectedVersion)
    }

    static var current: BugReportDeviceContext {
        let process = ProcessInfo.processInfo
        let os = process.operatingSystemVersion
        let machine = Host.current().localizedName ?? process.hostName
        let system = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        return BugReportDeviceContext(
            environment: "\(machine) · \(system)",
            affectedVersion: versionAndBuild(version: version, build: build)
        )
    }

    static func versionAndBuild(version: String?, build: String?) -> String {
        switch (version?.nilIfBlank, build?.nilIfBlank) {
        case let (.some(version), .some(build)): "\(version) (build \(build))"
        case let (.some(version), .none): version
        case let (.none, .some(build)): "Build \(build)"
        case (.none, .none): "Development build"
        }
    }
}
