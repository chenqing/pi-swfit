import Foundation

/// Compatibility shim for the older Swift public API. New callers use formatUserAgent.
public func getPiUserAgent() -> String { formatUserAgent() }
