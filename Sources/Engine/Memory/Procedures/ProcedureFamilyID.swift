/// ProcedureFamilyID identifies an application's procedure across versions by its supersedes root.
public struct ProcedureFamilyID: Sendable, Hashable, Codable {
    public let bundleID: String
    public let rootRouteUUID: String

    public init(bundleID: String, rootRouteUUID: String) {
        self.bundleID = bundleID
        self.rootRouteUUID = rootRouteUUID
    }
}
