import Foundation
import Observation
import PiAI

@MainActor @Observable
public final class ApprovalCenter {
    public internal(set) var permissionMode: ChatPermissionMode = .manual
    public private(set) var pending: [ChatApproval] = []
    @ObservationIgnored private var decisions: [String: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var rejected: Set<String> = []
    public init() {}

    public func resolve(_ id: String, allow: Bool) {
        guard let continuation = decisions.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        if !allow { rejected.insert(id) }
        continuation.resume(returning: allow)
    }

    func wasRejected(_ id: String) -> Bool { rejected.contains(id) }
    func reset() { cancelAll(); rejected.removeAll() }
    func cancelAll() { for id in Array(decisions.keys) { resolve(id, allow: false) } }

    func request(_ request: ChatApproval, signal: AbortSignal?) async -> Bool {
        guard signal?.aborted != true, !Task.isCancelled else { return false }
        let listener = signal?.addEventListener { [weak self] in
            Task { @MainActor [weak self] in self?.resolve(request.id, allow: false) }
        }
        defer { if let listener { signal?.removeEventListener(listener) } }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard signal?.aborted != true, !Task.isCancelled else {
                    continuation.resume(returning: false); return
                }
                // Tool-call IDs are unique within a run. Never replace a live waiter.
                guard decisions[request.id] == nil else { continuation.resume(returning: false); return }
                decisions[request.id] = continuation
                pending.append(request)
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.resolve(request.id, allow: false) }
        }
    }
}
