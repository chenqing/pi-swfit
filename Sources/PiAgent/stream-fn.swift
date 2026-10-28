import Foundation
import PiAI

// Port of packages/agent/src/stream-fn.ts

private let defaultStreamFn = Locked<StreamFn?>(nil)

/// Configure the fallback used by Agent and low-level loops when callers omit streamFn.
///
/// Hosts that provide a default model runtime can install its stream function here
/// without making pi-agent-core depend on a provider catalog or compatibility layer.
public func setDefaultStreamFn(_ streamFn: StreamFn?) {
    defaultStreamFn.withLock { $0 = streamFn }
}

func getDefaultStreamFn() throws -> StreamFn {
    guard let streamFn = defaultStreamFn.current else {
        throw PiError("No default stream function configured. Pass streamFn explicitly or call setDefaultStreamFn().")
    }
    return streamFn
}
