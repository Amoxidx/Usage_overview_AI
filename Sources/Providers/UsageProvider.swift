import Foundation

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> UsageReading
}
