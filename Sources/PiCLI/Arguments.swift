import Foundation
import PiAI

public struct CLIArguments: Sendable {
    public var provider = "openai"
    public var providerExplicit = false
    public var connection: String?
    public var listConnections = false
    public var model: String?
    public var api: String?
    public var baseURL: String?
    public var mode = "text"
    public var printMode = false
    public var noSession = false
    public var continueSession = false
    public var session: String?
    public var sessionDir: String?
    public var agentDir: String?
    public var systemPrompt: String?
    public var thinking: ModelThinkingLevel?
    public var tools = ["read", "bash", "edit", "write"]
    public var messages: [String] = []
    public var help = false
    public var version = false
    public var demo = false
    public var trustProject = false
    public init(_ arguments: [String]) throws {
        var i = 0
        while i < arguments.count {
            let flag = arguments[i]
            func value() throws -> String {
                i += 1
                guard i < arguments.count else { throw PiError("Missing value for \(flag)") }
                return arguments[i]
            }
            switch flag {
            case "-h", "--help": help = true
            case "-v", "--version": version = true
            case "-p", "--print": printMode = true
            case "--mode": mode = try value(); guard ["text", "json"].contains(mode) else { throw PiError("Supported modes: text, json. RPC is not implemented.") }
            case "--provider": provider = try value(); providerExplicit = true
            case "--connection": connection = try value()
            case "--list-connections": listConnections = true
            case "--model": model = try value()
            case "--api": api = try value()
            case "--base-url": baseURL = try value()
            case "--no-session": noSession = true
            case "-c", "--continue": continueSession = true
            case "--session": session = try value()
            case "--session-dir": sessionDir = try value()
            case "--agent-dir": agentDir = try value()
            case "--system-prompt": systemPrompt = try value()
            case "--thinking":
                let raw = try value()
                guard let level = ModelThinkingLevel(rawValue: raw) else { throw PiError("Unknown thinking level: \(raw)") }
                thinking = level
            case "--no-tools": tools = []
            case "--tools":
                tools = try value().split(separator: ",").map(String.init)
                guard tools.allSatisfy({ ["read", "bash", "edit", "write"].contains($0) }) else { throw PiError("Available tools: read,bash,edit,write") }
            case "--demo": demo = true
            case "--trust-project": trustProject = true
            case "--": messages += arguments.dropFirst(i + 1); i = arguments.count; continue
            default:
                guard !flag.hasPrefix("-") else { throw PiError("Unsupported option: \(flag). Run pf --help.") }
                messages.append(flag)
            }
            i += 1
        }
        if connection != nil && (model != nil || api != nil || baseURL != nil || providerExplicit || demo) { throw PiError("Use --connection by itself to select saved model routing") }
        if noSession && (continueSession || session != nil) { throw PiError("--no-session cannot be combined with --continue or --session") }
        if continueSession && session != nil { throw PiError("Choose --continue or --session") }
    }
}
