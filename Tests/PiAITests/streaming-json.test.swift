import Foundation
import Testing
@testable import PiAI

@Suite("Incremental streaming JSON")
struct StreamingJsonTests {
    @Test func partialValuesAndImmutableSnapshots() {
        let parser = StreamingJsonParser()
        #expect(parser.snapshot() == nil)
        parser.append(#"{"path":"a","items":[{"text":"hel"#)
        let first = parser.snapshot()
        #expect(first == ["path": "a", "items": [["text": "hel"]]])
        parser.append(#"lo"},true,12e"#)
        #expect(parser.snapshot() == ["path": "a", "items": [["text": "hello"], true, 12]])
        parser.append("+2],\"tail\":null}")
        #expect(parser.snapshot() == ["path": "a", "items": [["text": "hello"], true, 1200], "tail": nil])
        #expect(first == ["path": "a", "items": [["text": "hel"]]])
    }

    @Test func escapesWhitespaceAndSurrogateBoundaries() throws {
        let source = #"{"x":"a\n\t\u4e2d\ud83d\ude00 ","__proto__":{"ok":true}}"#
        let expected = try JsonValue.parse(source)
        for width in 1...17 {
            let args = ToolCallArgumentsStream()
            let chars = Array(source)
            var last = JsonObject()
            for start in stride(from: 0, to: chars.count, by: width) {
                last = args.append(String(chars[start..<min(start + width, chars.count)]))
            }
            #expect(.object(last) == expected)
            #expect(.object(args.finish().arguments) == expected)
            #expect(args.finish().argumentsError == nil)
        }
        let parser = StreamingJsonParser()
        parser.append("{\"x\":\"raw\n\\d ")
        #expect(parser.snapshot() == ["x": "raw\n\\d "])
    }

    @Test func changesReconstructCompletedValues() {
        let parser = StreamingJsonParser()
        #expect(parser.append(#"{"text":"hel"#) == [
            .set(path: [], value: [:]), .set(path: [.member("text")], value: "hel")])
        #expect(parser.append(#"lo","n":12"#) == [.append(path: [.member("text")], text: "lo")])
        #expect(parser.append("}") == [.set(path: [.member("n")], value: 12)])
    }

    @Test func changeEventsPreserveSplitSurrogatePairs() {
        let parser = StreamingJsonParser()
        #expect(parser.append(#"{"text":"\ud83d"#) == [
            .set(path: [], value: [:]), .set(path: [.member("text")], value: "")])
        #expect(parser.append(#"\ude00"}"#) == [.append(path: [.member("text")], text: "😀")])
        #expect(parser.snapshot() == ["text": "😀"])
    }

    @Test func malformedAndProviderReplacementRemainStrictAtExecution() {
        let args = ToolCallArgumentsStream()
        _ = args.append(#"{"value":"partial"#)
        #expect(args.finish().argumentsError != nil)
        let appended = args.replace(#"{"value":"partial complete"}"#)
        #expect(appended.delta == #" complete"}"#)
        #expect(appended.arguments["value"] == "partial complete")
        let replaced = args.replace(#"{"other":42}"#)
        #expect(replaced.delta == nil)
        #expect(args.finish().arguments == ["other": 42])
        _ = args.replace("[1,2]")
        #expect(args.finish().argumentsError != nil)
        #expect(args.append("").isEmpty)
    }

    @Test func randomizedChunksMatchStrictFinalParse() throws {
        var seed: UInt64 = 42
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % 1000) }
        let pieces = ["中文", "😀", "\\", "\"", "\n", "\t", " ", "é", "{]"]
        for _ in 0..<200 {
            let text = (0..<20).map { _ in pieces[next() % pieces.count] }.joined()
            let value: JsonValue = ["path": .string(text), "array": [true, nil, .number(Double(next())), ["nested": .string(text)]]]
            let chars = Array(value.serialized())
            let parser = StreamingJsonParser()
            var offset = 0
            while offset < chars.count {
                let end = min(offset + 1 + next() % 11, chars.count)
                parser.append(String(chars[offset..<end])); _ = parser.snapshot(); offset = end
            }
            #expect(parser.snapshot() == value)
        }
    }

    @Test func largeArgumentsAndWideContainersStayBounded() throws {
        let content = String(repeating: "line \"quoted\" \\ end\n", count: 25_000)
        let source = JsonValue.object(["path": "a.html", "content": .string(content)]).serialized()
        let bytes = Array(source.utf8)
        let args = ToolCallArgumentsStream()
        let start = ContinuousClock.now
        var shown = 0
        var retained: [JsonObject] = []
        for index in stride(from: 0, to: bytes.count, by: 32) {
            let partial = args.append(String(decoding: bytes[index..<min(index + 32, bytes.count)], as: UTF8.self))
            let count = partial["content"]?.stringValue?.utf8.count ?? 0
            #expect(count >= shown); shown = count
            if index % 16_000 == 0 { retained.append(partial) }
        }
        #expect(args.finish().arguments["content"] == .string(content))
        #expect(start.duration(to: .now) < .seconds(10))
        #expect(retained.first?["content"]?.stringValue != content)

        let parser = StreamingJsonParser()
        parser.append("[")
        for index in 0..<10_000 { parser.append(index == 0 ? "0" : ",\(index)"); _ = parser.snapshot() }
        parser.append("]")
        #expect(parser.snapshot()?.arrayValue?.count == 10_000)
        #expect(start.duration(to: .now) < .seconds(15))
    }
}
