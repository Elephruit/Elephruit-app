import ElephruitCore
import Foundation
import SwiftData

/// Records-specific state attached to the universal `Item` node.
///
/// People keep their `PersonProfile`; Records does not replace or duplicate it. This small
/// satellite supplies only the concerns shared by every subject: type, provenance, filing state,
/// and a flexible set of type-specific facts.
@Model
public final class RecordProfile {
    public var id: UUID = UUID()
    public var typeRaw: String = RecordType.other.rawValue
    public var originRaw: String = RecordOrigin.manual.rawValue
    public var isUnsorted: Bool = false
    public var detailsData: Data?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var item: Item?

    public init(
        id: UUID = UUID(),
        type: RecordType,
        origin: RecordOrigin = .manual,
        isUnsorted: Bool = false,
        details: [String: String] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.originRaw = origin.rawValue
        self.isUnsorted = isUnsorted
        self.detailsData = details.isEmpty ? nil : try? JSONEncoder().encode(details)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var type: RecordType {
        get { RecordType(rawValue: typeRaw) ?? .other }
        set { typeRaw = newValue.rawValue }
    }

    public var origin: RecordOrigin {
        get { RecordOrigin(rawValue: originRaw) ?? .manual }
        set { originRaw = newValue.rawValue }
    }

    public var details: [String: String] {
        get {
            guard let detailsData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: detailsData)) ?? [:]
        }
        set { detailsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
}
