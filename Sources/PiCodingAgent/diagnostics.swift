// Port: packages/coding-agent/src/core/diagnostics.ts @ 42cb822f1c5d3153069dd0661bfd297424666cf1
public struct ResourceCollision: Sendable, Hashable {
    public var resourceType: String
    public var name: String
    public var winnerPath: String
    public var loserPath: String
    public var winnerSource: String?
    public var loserSource: String?
}
public struct ResourceDiagnostic: Sendable, Hashable {
    public enum Kind: String, Sendable { case warning, error, collision }
    public var type: Kind
    public var message: String
    public var path: String?
    public var collision: ResourceCollision?
    public init(type: Kind, message: String, path: String? = nil, collision: ResourceCollision? = nil) {
        self.type = type; self.message = message; self.path = path; self.collision = collision
    }
}
