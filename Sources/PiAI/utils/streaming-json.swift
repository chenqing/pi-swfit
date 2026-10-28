import Foundation

// Port of pi@d5b3de22 packages/ai/src/utils/streaming-json.ts.
// Swift strings have no JavaScript-style ropes. Charge open string materialization to the same
// snapshot credit as open containers; previews may lag on large strings, but parsing and copying
// stay bounded by the input size. Completed values and previously returned snapshots are immutable.

public enum JsonPathComponent: Sendable, Hashable {
    case member(String)
    case element(Int)
}
public typealias JsonPath = [JsonPathComponent]
public enum JsonChange: Sendable, Hashable {
    case set(path: JsonPath, value: JsonValue)
    case append(path: JsonPath, text: String)
}

/// Incremental tolerant preview parser. Final tool arguments must still pass the strict parser.
/// Owned by one provider stream, like its upstream counterpart; not shared across tasks.
public final class StreamingJsonParser {
    private enum Slot { case root, member(String), element(Int) }
    private enum Phase { case key, colon, value, comma }
    private final class Frame {
        var members = JsonObject()
        var elements: [JsonValue] = []
        let isArray: Bool
        let slot: Slot?
        let path: JsonPath?
        let reportsInside: Bool
        var key: String?
        var phase: Phase
        var count: Int { isArray ? elements.count : members.count }
        var value: JsonValue { isArray ? .array(elements) : .object(members) }
        init(isArray: Bool, slot: Slot?, path: JsonPath?) {
            self.isArray = isArray; self.slot = slot; self.path = path
            reportsInside = path.map { $0.count < 32 } ?? false
            phase = isArray ? .value : .key
        }
        func set(_ slot: Slot, _ value: JsonValue) {
            switch slot {
            case .root: break
            case .member(let key): members[key] = value
            case .element(let index):
                if index == elements.count { elements.append(value) }
                else if elements.indices.contains(index) { elements[index] = value }
            }
        }
    }
    private final class OpenString {
        let isKey: Bool
        let slot: Slot?
        let path: JsonPath?
        var units: [UInt16] = []
        var escape: [UInt16] = []
        var change: Int?
        // Swift String cannot carry JS's lone UTF-16 surrogate; defer it in change events
        // until its partner arrives, so consumers can concatenate valid Unicode deltas.
        var unreportedHighSurrogate: UInt16?
        init(isKey: Bool, slot: Slot?, path: JsonPath?) {
            self.isKey = isKey; self.slot = slot; self.path = path
        }
        var text: String { String(decoding: units, as: UTF16.self) }
    }
    private final class OpenChange {
        let path: JsonPath
        let isSet: Bool
        var value: JsonValue?
        var units: [UInt16]?
        init(path: JsonPath, value: JsonValue) { self.path = path; isSet = true; self.value = value }
        init(path: JsonPath, units: [UInt16], isSet: Bool = false) {
            self.path = path; self.units = units; self.isSet = isSet
        }
        var result: JsonChange {
            if let units {
                let text = String(decoding: units, as: UTF16.self)
                return isSet ? .set(path: path, value: .string(text)) : .append(path: path, text: text)
            }
            return .set(path: path, value: value ?? .null)
        }
    }
    private var root: JsonValue?
    private var done = false
    private var stack: [Frame] = []
    private var string: OpenString?
    private var scalar: [UInt16] = []
    private var scalarSlot: Slot?
    private var pathCost = 0
    private var credit = 0
    private var dirty = false
    private var lastSnapshot: JsonValue?
    private var changes: [OpenChange] = []

    public init() {}

    @discardableResult public func append(_ text: String) -> [JsonChange] {
        let units = Array(text.utf16)
        credit += 256 + 8 * units.count
        changes = []
        string?.change = nil
        var index = 0
        while index < units.count && !done {
            if let open = string { index = readString(open, units, index) }
            else if !scalar.isEmpty { index = readScalar(units, index) }
            else { structural(units[index]); index += 1 }
        }
        return changes.map(\.result)
    }

    public func snapshot() -> JsonValue? {
        guard dirty else { return lastSnapshot }
        let pending = pendingScalar()
        // UTF-16 decoding allocates a flat Swift String, unlike JS rope concatenation.
        let stringCost = string.flatMap { $0.isKey || $0.slot == nil ? nil : $0.units.count } ?? 0
        let cost = pathCost + stringCost + (pending == nil ? 0 : 1)
        guard cost <= credit else { return lastSnapshot }
        credit -= cost; dirty = false
        var overlay = pending
        if let open = string, !open.isKey, let slot = open.slot { overlay = (slot, .string(open.text)) }
        lastSnapshot = copyOpenPath(overlay)
        return lastSnapshot
    }

    private func readString(_ open: OpenString, _ text: [UInt16], _ start: Int) -> Int {
        var runStart = start
        for index in start..<text.count {
            let code = text[index]
            if !open.escape.isEmpty {
                if continueEscape(open, code) { runStart = index + 1; continue }
                runStart = index
            }
            if code == 34 {
                if index > runStart { appendString(open, text[runStart..<index]) }
                endString(open)
                return index + 1
            }
            if code == 92 {
                if index > runStart { appendString(open, text[runStart..<index]) }
                open.escape = [92]; runStart = index + 1
            }
        }
        if text.count > runStart { appendString(open, text[runStart...]) }
        return text.count
    }

    private func readScalar(_ text: [UInt16], _ start: Int) -> Int {
        var end = start
        while end < text.count && !Self.isDelimiter(text[end]) { end += 1 }
        if end > start {
            scalar.append(contentsOf: text[start..<end])
            if scalarSlot != nil { dirty = true }
        }
        if end < text.count { endScalar() }
        return end
    }

    private func structural(_ code: UInt16) {
        switch code {
        case 32, 9, 10, 13: return
        case 34: startString()
        case 123, 91: openContainer(isArray: code == 91)
        case 125, 93: closeContainer()
        case 58:
            if let frame = stack.last, !frame.isArray, frame.phase == .colon { frame.phase = .value }
        case 44:
            if let frame = stack.last { frame.phase = frame.isArray ? .value : .key }
        default:
            scalar = [code]; scalarSlot = valueSlot()
            if scalarSlot != nil { dirty = true }
        }
    }

    private func valueSlot() -> Slot? {
        guard let frame = stack.last else { return root == nil ? .root : nil }
        if frame.isArray { return .element(frame.elements.count) }
        if (frame.phase == .value || frame.phase == .colon), let key = frame.key { return .member(key) }
        return nil
    }

    private func startString() {
        if let frame = stack.last, !frame.isArray, frame.phase == .key || frame.phase == .comma {
            string = OpenString(isKey: true, slot: nil, path: nil)
            return
        }
        let slot = valueSlot(), path = reportedPath(valueSlot())
        let open = OpenString(isKey: false, slot: slot, path: path)
        string = open; place(slot, .string(""))
        if let path {
            changes.append(OpenChange(path: path, units: [], isSet: true))
            open.change = changes.count - 1
        }
    }

    private func reportedPath(_ slot: Slot?) -> JsonPath? {
        guard let slot else { return nil }
        if case .root = slot { return [] }
        guard let frame = stack.last, frame.reportsInside, var path = frame.path else { return nil }
        switch slot {
        case .root: break
        case .member(let key): path.append(.member(key))
        case .element(let index): path.append(.element(index))
        }
        return path
    }

    private func continueEscape(_ open: OpenString, _ code: UInt16) -> Bool {
        if open.escape.count == 1 {
            let simple: UInt16?
            switch code {
            case 34, 92, 47: simple = code
            case 98: simple = 8
            case 102: simple = 12
            case 110: simple = 10
            case 114: simple = 13
            case 116: simple = 9
            default: simple = nil
            }
            if let simple { open.escape = []; appendString(open, [simple][...]); return true }
            if code == 117 { open.escape.append(code); return true }
            open.escape = []; appendString(open, [UInt16(92)][...]); return false
        }
        if Self.isHexDigit(code) {
            open.escape.append(code)
            guard open.escape.count == 6 else { return true }
            let digits = String(decoding: open.escape.dropFirst(2), as: UTF16.self)
            let decoded = UInt16(digits, radix: 16)!
            open.escape = []; appendString(open, [decoded][...]); return true
        }
        let literal = open.escape; open.escape = []
        appendString(open, literal[...]); return false
    }

    private func appendString(_ open: OpenString, _ units: ArraySlice<UInt16>) {
        open.units.append(contentsOf: units)
        guard !open.isKey else { return }
        if open.slot != nil { dirty = true }
        guard let path = open.path else { return }
        var reported = Array(units)
        if let high = open.unreportedHighSurrogate { reported.insert(high, at: 0); open.unreportedHighSurrogate = nil }
        if let last = reported.last, (0xD800...0xDBFF).contains(last) {
            open.unreportedHighSurrogate = reported.removeLast()
        }
        reportString(open, path, reported)
    }

    private func reportString(_ open: OpenString, _ path: JsonPath, _ units: [UInt16]) {
        guard !units.isEmpty else { return }
        if let index = open.change, index == changes.count - 1 {
            changes[index].units?.append(contentsOf: units)
        } else {
            changes.append(OpenChange(path: path, units: units))
            open.change = changes.count - 1
        }
    }

    private func endString(_ open: OpenString) {
        string = nil
        if open.isKey {
            stack.last?.key = open.text; stack.last?.phase = .colon
        } else {
            if let high = open.unreportedHighSurrogate, let path = open.path { reportString(open, path, [high]) }
            place(open.slot, .string(open.text)); valueEnded()
        }
    }

    private func endScalar() {
        let token = String(decoding: scalar, as: UTF16.self), slot = scalarSlot
        scalar = []; scalarSlot = nil
        if let value = Self.scalarValue(token) {
            place(slot, value)
            if let path = reportedPath(slot) { changes.append(OpenChange(path: path, value: value)) }
        }
        valueEnded()
    }

    private func pendingScalar() -> (Slot, JsonValue)? {
        guard let slot = scalarSlot, !scalar.isEmpty, scalar.count <= 64 else { return nil }
        let token = String(decoding: scalar, as: UTF16.self)
        for (literal, value) in Self.literals where literal.hasPrefix(token) { return (slot, value) }
        if let value = Self.scalarValue(token) { return (slot, value) }
        if let match = token.range(of: #"^-?(?:0|[1-9]\d*)(?:\.\d+)?(?=[eE][+-]?$)"#, options: .regularExpression),
           let number = Double(token[match]) { return (slot, .number(number)) }
        return nil
    }

    private func openContainer(isArray: Bool) {
        let slot = valueSlot(), path = reportedPath(valueSlot())
        let value: JsonValue = isArray ? .array([]) : .emptyObject
        place(slot, value)
        stack.append(Frame(isArray: isArray, slot: slot, path: path))
        pathCost += 1; dirty = true
        if let path { changes.append(OpenChange(path: path, value: value)) }
    }

    private func closeContainer() {
        guard let frame = stack.popLast() else { return }
        pathCost -= frame.count + 1; dirty = true
        // Swift containers are values, so commit the finished child to its parent here.
        place(frame.slot, frame.value)
        if let path = frame.path, !frame.reportsInside {
            changes.append(OpenChange(path: path, value: frame.value))
        }
        valueEnded()
    }

    private func valueEnded() {
        if let frame = stack.last { frame.phase = .comma }
        else if root != nil { done = true }
    }

    private func place(_ slot: Slot?, _ value: JsonValue) {
        guard let slot else { return }
        dirty = true
        if case .root = slot { root = value; return }
        guard let frame = stack.last else { return }
        let before = frame.count
        frame.set(slot, value)
        pathCost += frame.count - before
    }

    private func copyOpenPath(_ pending: (Slot, JsonValue)?) -> JsonValue? {
        if stack.isEmpty {
            if let pending, case .root = pending.0 { return pending.1 }
            return root
        }
        var child: JsonValue?, childSlot: Slot?
        for depth in stack.indices.reversed() {
            let frame = stack[depth]
            var copy = frame.value
            if depth == stack.count - 1, let pending { Self.setSlot(&copy, pending.0, pending.1) }
            if let child, let childSlot { Self.setSlot(&copy, childSlot, child) }
            child = copy; childSlot = frame.slot
        }
        if case .root? = childSlot { return child }
        return root
    }

    private static func setSlot(_ container: inout JsonValue, _ slot: Slot, _ value: JsonValue) {
        switch slot {
        case .root: break
        case .member(let key): container[key] = value
        case .element(let index):
            guard case .array(var array) = container else { return }
            if index == array.count { array.append(value) }
            else if array.indices.contains(index) { array[index] = value }
            container = .array(array)
        }
    }
    private static let literals: [(String, JsonValue)] = [("true", .bool(true)), ("false", .bool(false)), ("null", .null)]
    private static func scalarValue(_ token: String) -> JsonValue? {
        for (literal, value) in literals where literal == token { return value }
        guard token.range(of: #"^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
              let number = Double(token) else { return nil }
        return .number(number)
    }
    private static func isDelimiter(_ code: UInt16) -> Bool {
        switch code { case 32, 9, 10, 13, 44, 58, 123, 125, 91, 93, 34: true; default: false }
    }
    private static func isHexDigit(_ code: UInt16) -> Bool {
        (48...57).contains(code) || (65...70).contains(code) || (97...102).contains(code)
    }
}

/// Per-call scratch state, kept out of partial messages and persisted transcripts.
public final class ToolCallArgumentsStream {
    private var raw: [UInt8] = []
    private var parser = StreamingJsonParser()
    public init() {}
    public var text: String { String(decoding: raw, as: UTF8.self) }
    @discardableResult public func append(_ delta: String) -> JsonObject {
        raw.append(contentsOf: delta.utf8)
        parser.append(delta)
        return parser.snapshot()?.objectValue ?? JsonObject()
    }
    public func replace(_ text: String) -> (delta: String?, arguments: JsonObject) {
        let bytes = Array(text.utf8)
        if bytes.starts(with: raw) {
            let delta = String(decoding: bytes.dropFirst(raw.count), as: UTF8.self)
            return (delta, delta.isEmpty ? parser.snapshot()?.objectValue ?? JsonObject() : append(delta))
        }
        raw = []; parser = StreamingJsonParser()
        return (nil, append(text))
    }
    public func finish() -> ParsedToolCallArguments { parseToolCallArguments(text) }
}
