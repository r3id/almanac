import Foundation

/// A school, so terms can belong to one child rather than to the household.
///
/// Deliberately invisible when there's only one. Nothing shows a school name,
/// asks which school, or groups anything by school until a second one exists —
/// most people have one and shouldn't pay for a case they don't have.
nonisolated struct School: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""

    init(id: UUID = UUID(), name: String = "") {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}
