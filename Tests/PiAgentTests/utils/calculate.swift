import Foundation
import PiAI
import PiAgent

// Port of packages/agent/test/utils/calculate.ts
//
// Swift: upstream evaluates the expression with `new Function`; here a small arithmetic parser
// (numbers, + - * / %, parentheses) stands in for it.

func calculate(_ expression: String) throws -> AgentToolResult {
    var parser = ArithmeticParser(Array(expression))
    let result = try parser.parse()
    let rendered = result.rounded() == result && abs(result) < 1e15 ? String(Int(result)) : String(result)
    return AgentToolResult(content: [.text(TextContent(text: "\(expression) = \(rendered)"))], details: nil)
}

let calculateSchema: JsonValue = [
    "type": "object",
    "properties": ["expression": ["type": "string", "description": "The mathematical expression to evaluate"]],
    "required": ["expression"],
]

let calculateTool = AgentTool(
    name: "calculate",
    label: "Calculator",
    description: "Evaluate mathematical expressions",
    parameters: calculateSchema
) { _, args, _, _ in
    try calculate(args["expression"]?.stringValue ?? "")
}

func createCalculateToolWithUsage(_ usage: Usage) -> AgentTool {
    var tool = calculateTool
    tool.execute = { _, args, _, _ in
        var result = try calculate(args["expression"]?.stringValue ?? "")
        result.usage = usage
        return result
    }
    return tool
}

private struct ArithmeticParser {
    let chars: [Character]
    var index = 0
    init(_ chars: [Character]) { self.chars = chars }

    mutating func parse() throws -> Double {
        let value = try expression()
        skipSpaces()
        if index != chars.count { throw PiError("Unexpected token '\(chars[index])'") }
        return value
    }

    private mutating func skipSpaces() { while index < chars.count, chars[index] == " " { index += 1 } }

    private mutating func expression() throws -> Double {
        var value = try term()
        while true {
            skipSpaces()
            guard index < chars.count, chars[index] == "+" || chars[index] == "-" else { return value }
            let op = chars[index]; index += 1
            let rhs = try term()
            value = op == "+" ? value + rhs : value - rhs
        }
    }

    private mutating func term() throws -> Double {
        var value = try factor()
        while true {
            skipSpaces()
            guard index < chars.count, "*/%".contains(chars[index]) else { return value }
            let op = chars[index]; index += 1
            let rhs = try factor()
            value = op == "*" ? value * rhs : op == "/" ? value / rhs : value.truncatingRemainder(dividingBy: rhs)
        }
    }

    private mutating func factor() throws -> Double {
        skipSpaces()
        guard index < chars.count else { throw PiError("Unexpected end of input") }
        if chars[index] == "-" { index += 1; return -(try factor()) }
        if chars[index] == "(" {
            index += 1
            let value = try expression()
            skipSpaces()
            guard index < chars.count, chars[index] == ")" else { throw PiError("Unexpected end of input") }
            index += 1
            return value
        }
        let start = index
        while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
        guard start < index, let value = Double(String(chars[start..<index])) else {
            throw PiError("Unexpected token '\(chars[index])'")
        }
        return value
    }
}
