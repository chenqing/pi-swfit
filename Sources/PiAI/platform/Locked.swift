import Foundation

/// Lock-protected mutable state. Pi code that upstream relies on JavaScript's single thread for
/// (event streams, abort signals, queues) keeps its state in one of these.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    @discardableResult
    public func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value { withLock { $0 } }
}

/// `Date.now()`: Unix time in integer milliseconds.
public func dateNow() -> Int { Int((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

/// `performance.now()`: monotonic milliseconds.
public func performanceNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

/// Plain `Error` with a message, the equivalent of `new Error(message)`.
public struct PiError: Error, CustomStringConvertible, LocalizedError, Sendable, Equatable {
    public var name: String
    public var message: String
    public init(_ message: String, name: String = "Error") {
        self.message = message
        self.name = name
    }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// `error instanceof Error ? error.message : String(error)`.
public func errorMessage(_ error: any Error) -> String {
    if let error = error as? PiError { return error.message }
    if error is CancellationError { return "The operation was aborted" }
    if let error = error as? any LocalizedError, let description = error.errorDescription { return description }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain || ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain { return ns.localizedDescription }
    return String(describing: error)
}
