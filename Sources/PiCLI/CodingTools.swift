import PiAgent
import PiHost

/// Compatibility entry point; tools are shared by the CLI and native chat host.
public func createCodingTools(cwd: String) -> [AgentTool] { PiHost.createCodingTools(cwd: cwd) }
