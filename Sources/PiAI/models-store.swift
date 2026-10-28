import Foundation

// Port of packages/ai/src/models-store.ts

public struct ModelsStoreEntry: Sendable {
    /// Persisted models of every type.
    public var models: [AnyModel]
    /// Unix timestamp from the remote catalog's Last-Modified header.
    public var lastModified: Int?
    /// Unix timestamp of the last completed remote check.
    public var checkedAt: Int?
    /// Opaque validator from the remote catalog's ETag header, stored verbatim
    /// (quotes included) and echoed back as If-None-Match.
    public var etag: String?
    public init(models: [AnyModel], lastModified: Int? = nil, checkedAt: Int? = nil, etag: String? = nil) {
        self.models = models; self.lastModified = lastModified; self.checkedAt = checkedAt; self.etag = etag
    }
}

public struct ModelsStoreOperationOptions: Sendable {
    public var signal: AbortSignal?
    public init(signal: AbortSignal? = nil) { self.signal = signal }
}

/// Persistent model catalogs keyed by provider ID.
public protocol ModelsStore: Sendable {
    func read(_ providerId: String, _ options: ModelsStoreOperationOptions?) async throws -> ModelsStoreEntry?
    func write(_ providerId: String, _ entry: ModelsStoreEntry, _ options: ModelsStoreOperationOptions?) async throws
    func delete(_ providerId: String, _ options: ModelsStoreOperationOptions?) async throws
}

extension ModelsStore {
    public func read(_ providerId: String) async throws -> ModelsStoreEntry? { try await read(providerId, nil) }
    public func write(_ providerId: String, _ entry: ModelsStoreEntry) async throws { try await write(providerId, entry, nil) }
    public func delete(_ providerId: String) async throws { try await delete(providerId, nil) }
}

/// `structuredClone` is implicit: entries are value types.
public final class InMemoryModelsStore: ModelsStore {
    private let entries = Locked([String: ModelsStoreEntry]())

    public init() {}

    public func read(_ providerId: String, _ options: ModelsStoreOperationOptions? = nil) async throws -> ModelsStoreEntry? {
        try options?.signal?.throwIfAborted()
        return entries.withLock { $0[providerId] }
    }

    public func write(_ providerId: String, _ entry: ModelsStoreEntry, _ options: ModelsStoreOperationOptions? = nil) async throws {
        try options?.signal?.throwIfAborted()
        entries.withLock { $0[providerId] = entry }
    }

    public func delete(_ providerId: String, _ options: ModelsStoreOperationOptions? = nil) async throws {
        try options?.signal?.throwIfAborted()
        entries.withLock { $0[providerId] = nil }
    }
}
