import Foundation
import PiAI

// Port of packages/coding-agent/src/core/usage-totals.ts

public struct UsageTotals: Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var cost: Double
    public init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cost: Double) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.cost = cost
    }
}

public func createUsageTotals() -> UsageTotals {
    UsageTotals(
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        cost: 0
    )
}

public func addUsageToTotals(_ totals: inout UsageTotals, _ usage: Usage) {
    totals.input += usage.input
    totals.output += usage.output
    totals.cacheRead += usage.cacheRead
    totals.cacheWrite += usage.cacheWrite
    totals.cost += usage.cost.total
}

/** Sum of two usages, keeping the optional token splits when either side reports them. */
public func combineUsage(_ first: Usage, _ second: Usage) -> Usage {
    Usage(
        input: first.input + second.input,
        output: first.output + second.output,
        cacheRead: first.cacheRead + second.cacheRead,
        cacheWrite: first.cacheWrite + second.cacheWrite,
        cacheWrite1h: first.cacheWrite1h != nil || second.cacheWrite1h != nil
            ? (first.cacheWrite1h ?? 0) + (second.cacheWrite1h ?? 0)
            : nil,
        reasoning: first.reasoning != nil || second.reasoning != nil
            ? (first.reasoning ?? 0) + (second.reasoning ?? 0)
            : nil,
        totalTokens: first.totalTokens + second.totalTokens,
        cost: UsageCost(
            input: first.cost.input + second.cost.input,
            output: first.cost.output + second.cost.output,
            cacheRead: first.cost.cacheRead + second.cost.cacheRead,
            cacheWrite: first.cost.cacheWrite + second.cost.cacheWrite,
            total: first.cost.total + second.cost.total
        )
    )
}

public struct UsageCostBreakdownEntry: Sendable, Hashable {
    public var key: String
    public var cost: Double
    public var tokens: Int
}

/** Group model-attributed usage by model and all other usage into a separate bucket. */
public func getUsageCostBreakdown(_ entries: [SessionEntry]) -> [UsageCostBreakdownEntry] {
    var keys: [String] = []
    var totalsByKey: [String: UsageTotals] = [:]

    for entry in entries {
        var key: String?
        var usage: Usage?
        if case .message(let e) = entry, case .assistant(let message) = e.message {
            key = "\(message.provider)/\(message.responseModel ?? message.model)"
            usage = message.usage
        } else if case .usage(let e) = entry {
            key = "\(e.provider)/\(e.model)"
            usage = e.usage
        } else if case .message(let e) = entry, case .toolResult(let message) = e.message, let toolUsage = message.usage {
            key = "Tools/summaries"
            usage = toolUsage
        } else if case .branchSummary(let e) = entry, let summaryUsage = e.usage {
            key = "Tools/summaries"
            usage = summaryUsage
        } else if case .compaction(let e) = entry, let summaryUsage = e.usage {
            key = "Tools/summaries"
            usage = summaryUsage
        }
        guard let key, !key.isEmpty, let usage else { continue }

        if totalsByKey[key] == nil {
            totalsByKey[key] = createUsageTotals()
            keys.append(key)
        }
        addUsageToTotals(&totalsByKey[key]!, usage)
    }

    let breakdown = keys.map { key -> UsageCostBreakdownEntry in
        let totals = totalsByKey[key]!
        return UsageCostBreakdownEntry(
            key: key,
            cost: totals.cost,
            tokens: totals.input + totals.output + totals.cacheRead + totals.cacheWrite
        )
    }
    // Swift: stable sort, like Array.prototype.sort.
    return breakdown
        .filter { $0.cost > 0 || $0.tokens > 0 }
        .enumerated()
        .sorted { $0.element.cost != $1.element.cost ? $0.element.cost > $1.element.cost : $0.offset < $1.offset }
        .map(\.element)
}
