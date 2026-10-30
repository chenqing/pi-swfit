import Foundation

// Port of utils/openrouter-cost.ts
//
// Swift: `OpenRouterUsageAccounting` is the raw usage JSON; the fields read are `cost`, `is_byok` and
// `cost_details` (`upstream_inference_cost`, `upstream_inference_prompt_cost`, `upstream_inference_completions_cost`).

private func isValidCost(_ value: JsonValue?) -> Double? {
    guard case .number(let number)? = value, number.isFinite, number >= 0 else { return nil }
    return number
}

public func isOpenRouterModel(_ model: Model) -> Bool {
    model.provider == "openrouter" || model.baseUrl.contains("openrouter.ai")
}

/// Replace the catalog total with OpenRouter's billed cost when the response contains complete, valid accounting.
public func applyOpenRouterReportedCost(_ usage: inout Usage, _ reported: JsonValue) {
    guard let cost = isValidCost(reported["cost"]) else { return }

    if reported["is_byok"] == .bool(false) {
        usage.cost.total = cost
        usage.cost.totalFromProvider = true
        return
    }

    if reported["is_byok"] == .bool(true) {
        guard let details = reported["cost_details"], details != .null else { return }
        var upstreamCost: JsonValue? = details["upstream_inference_cost"]
        if upstreamCost == .null {
            guard let promptCost = isValidCost(details["upstream_inference_prompt_cost"]),
                  let completionsCost = isValidCost(details["upstream_inference_completions_cost"]) else {
                return
            }
            upstreamCost = .number(promptCost + completionsCost)
        }
        guard let upstream = isValidCost(upstreamCost) else { return }
        usage.cost.total = cost + upstream
        usage.cost.totalFromProvider = true
    }
}
