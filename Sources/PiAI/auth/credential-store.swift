import Foundation

// Port of packages/ai/src/auth/credential-store.ts

/// Default in-memory credential store. Apps inject persistent stores.
/// Keyed by `Provider.id`, one credential per provider; see `CredentialStore`.
/// Writes are serialized per provider through a task chain.
public final class InMemoryCredentialStore: CredentialStore {
    private struct State {
        var credentials = JSMap<Credential>()
        var chains: [String: (id: Int, tail: Task<Void, Never>)] = [:]
        var nextChainId = 0
    }

    private let state = Locked(State())

    public init() {}

    /// Serialize tasks per provider id without releasing the chain before active work settles.
    private func enqueue<T: Sendable>(
        _ providerId: String,
        _ task: @escaping @Sendable () async throws -> T,
        _ options: AuthOperationOptions?
    ) async throws -> T {
        let signal = operationSignal(options?.signal)
        let queued: Task<T, any Error> = state.withLock { s in
            let previous = s.chains[providerId]?.tail
            let queued = Task<T, any Error> {
                await previous?.value
                try signal.throwIfAborted()
                return try await task()
            }
            let tail = Task<Void, Never> { _ = try? await queued.value }
            s.nextChainId += 1
            let id = s.nextChainId
            s.chains[providerId] = (id, tail)
            Task { [weak self] in
                await tail.value
                self?.state.withLock { s in
                    if s.chains[providerId]?.id == id { s.chains[providerId] = nil }
                }
            }
            return queued
        }
        return try await raceWithAbortSignal({ try await queued.value }, signal)
    }

    public func read(_ providerId: String, _ options: AuthOperationOptions? = nil) async throws -> Credential? {
        try options?.signal?.throwIfAborted()
        return state.withLock { $0.credentials[providerId] }
    }

    public func list(_ options: AuthOperationOptions? = nil) async throws -> [CredentialInfo] {
        try options?.signal?.throwIfAborted()
        return state.withLock { s in s.credentials.entries.map { CredentialInfo(providerId: $0.key, type: $0.value.type) } }
    }

    public func modify(
        _ providerId: String,
        _ fn: @escaping @Sendable (Credential?) async throws -> Credential?,
        _ options: AuthOperationOptions? = nil
    ) async throws -> Credential? {
        try await enqueue(
            providerId,
            { [self] in
                let current = state.withLock { $0.credentials[providerId] }
                let next = try await fn(current)
                try options?.signal?.throwIfAborted()
                if let next { state.withLock { $0.credentials[providerId] = next } }
                return next ?? current
            },
            options
        )
    }

    public func delete(_ providerId: String, _ options: AuthOperationOptions? = nil) async throws {
        try await enqueue(
            providerId,
            { [self] in
                state.withLock { $0.credentials[providerId] = nil }
            },
            options
        )
    }
}
