import Foundation
import PiAI
import Testing
@testable import PiCodingAgent

// Port of test/settings-manager-compaction.test.ts
//
// Not ported: tests built on `InMemorySettingsStorage` / `SettingsManager.fromStorage` (global + project merge,
// reload, project trust, flush) and the malformed-JSON cases (`null`, `"400000"`, `true`, `{}`, `[]`, malformed
// model entries): settings are a typed Swift value, so those shapes cannot be expressed. The numeric invalid
// values (-1, 1.5, MAX_SAFE_INTEGER + 1, NaN, ±Infinity) are covered through `inMemory` / `applyOverrides`.

private let model = SettingsModelRef(provider: "provider", id: "family/model")
private let modelKey = "provider/family/model"
private let defaults = CompactionSettings(enabled: true, reserveTokens: 16384, keepRecentTokens: 20000)

enum CompactionTokenFieldCase: String, CaseIterable, Sendable {
    case reserveTokens
    case keepRecentTokens

    func override(_ value: Double) -> Settings.CompactionModelOverride {
        switch self {
        case .reserveTokens: return Settings.CompactionModelOverride(reserveTokens: value)
        case .keepRecentTokens: return Settings.CompactionModelOverride(keepRecentTokens: value)
        }
    }

    func ordinary(_ value: Double, modelOverrides: [String: Settings.CompactionModelOverride]? = nil) -> Settings.CompactionSettings {
        switch self {
        case .reserveTokens: return Settings.CompactionSettings(reserveTokens: value, modelOverrides: modelOverrides)
        case .keepRecentTokens: return Settings.CompactionSettings(keepRecentTokens: value, modelOverrides: modelOverrides)
        }
    }
}

private let invalidValues: [Double] = [-1, 1.5, 9_007_199_254_740_992] // Number.MAX_SAFE_INTEGER + 1
private let nonFiniteValues: [Double] = [.nan, .infinity, -.infinity]

/// `String(value)` for the JS numbers above.
private func jsString(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
    if value == 9_007_199_254_740_992 { return "9007199254740992" }
    if value == value.rounded() { return String(Int(value)) }
    return String(value)
}

private func fieldValueCases(_ values: [Double]) -> [(CompactionTokenFieldCase, Double)] {
    CompactionTokenFieldCase.allCases.flatMap { field in values.map { (field, $0) } }
}

// Regression coverage for #8133.
@Suite("compaction model overrides") struct CompactionModelOverridesTests {
    @Test("uses defaults without compaction settings") func usesDefaults() throws {
        let manager = SettingsManager.inMemory()
        #expect(try manager.getCompactionSettings() == defaults)
        #expect(try manager.getCompactionSettings(model) == defaults)
    }

    @Test("resolves each field independently and keeps individual getters consistent") func resolvesIndependently() throws {
        let manager = SettingsManager.inMemory(Settings(compaction: Settings.CompactionSettings(
            reserveTokens: 8192,
            keepRecentTokens: 10000,
            modelOverrides: [modelKey: Settings.CompactionModelOverride(reserveTokens: 400000)]
        )))
        #expect(try manager.getCompactionSettings(model) == CompactionSettings(enabled: true, reserveTokens: 400000, keepRecentTokens: 10000))
        #expect(try manager.getCompactionReserveTokens(model) == 400000)
        #expect(try manager.getCompactionKeepRecentTokens(model) == 10000)
        #expect(try manager.getCompactionSettings() == CompactionSettings(enabled: true, reserveTokens: 8192, keepRecentTokens: 10000))

        manager.applyOverrides(Settings(compaction: Settings.CompactionSettings(
            modelOverrides: [modelKey: Settings.CompactionModelOverride(keepRecentTokens: 30000)]
        )))
        #expect(try manager.getCompactionKeepRecentTokens(model) == 30000)
        #expect(try manager.getCompactionReserveTokens(model) == 400000)
    }

    @Test("falls back to built-in defaults for missing fields") func fallsBack() throws {
        let manager = SettingsManager.inMemory(Settings(compaction: Settings.CompactionSettings(
            modelOverrides: [modelKey: Settings.CompactionModelOverride(keepRecentTokens: 1024)]
        )))
        var expected = defaults
        expected.keepRecentTokens = 1024
        #expect(try manager.getCompactionSettings(model) == expected)
    }

    @Test("matches exact provider/model IDs, including IDs containing slashes") func exactIds() throws {
        let manager = SettingsManager.inMemory(Settings(compaction: Settings.CompactionSettings(modelOverrides: [
            modelKey: Settings.CompactionModelOverride(reserveTokens: 400000),
            "provider/*": Settings.CompactionModelOverride(reserveTokens: 1),
            "family/model": Settings.CompactionModelOverride(reserveTokens: 2),
        ])))
        #expect(try manager.getCompactionReserveTokens(model) == 400000)
        for other in [
            SettingsModelRef(provider: "other", id: model.id),
            SettingsModelRef(provider: model.provider, id: "other"),
            SettingsModelRef(provider: model.provider, id: "family/Model"),
        ] {
            #expect(try manager.getCompactionSettings(other) == defaults)
        }
    }

    @Test("keeps enabled global and preserves overrides when saving the toggle") func togglePreservesOverrides() throws {
        // Swift: in-memory variant (upstream round-trips through InMemorySettingsStorage, flush and reload).
        let manager = SettingsManager.inMemory(Settings(compaction: Settings.CompactionSettings(
            modelOverrides: [modelKey: Settings.CompactionModelOverride(enabled: false, reserveTokens: 400000)]
        )))
        #expect(try manager.getCompactionSettings(model).enabled == true)
        manager.setCompactionEnabled(false)
        #expect(try manager.getCompactionSettings(model) == CompactionSettings(enabled: false, reserveTokens: 400000, keepRecentTokens: 20000))
    }

    @Test("model override reports invalid token values", arguments: fieldValueCases(invalidValues))
    func invalidOverride(_ field: CompactionTokenFieldCase, _ value: Double) throws {
        let manager = SettingsManager.inMemory(Settings(compaction: Settings.CompactionSettings(
            modelOverrides: [modelKey: field.override(value)]
        )))
        let message = thrownMessage { _ = try manager.getCompactionSettings(model) }
        #expect(message == "Invalid compaction.modelOverrides[\"\(modelKey)\"].\(field.rawValue) setting: \(jsString(value)). Expected a non-negative safe integer.")
        #expect(try manager.getCompactionSettings() == defaults)
        #expect(try manager.getCompactionSettings(SettingsModelRef(provider: "other", id: model.id)) == defaults)
    }

    @Test("model override reports non-finite runtime values", arguments: fieldValueCases(nonFiniteValues))
    func nonFiniteOverride(_ field: CompactionTokenFieldCase, _ value: Double) {
        let manager = SettingsManager.inMemory()
        manager.applyOverrides(Settings(compaction: Settings.CompactionSettings(modelOverrides: [modelKey: field.override(value)])))
        let message = thrownMessage { _ = try manager.getCompactionSettings(model) }
        #expect(message?.contains("Invalid compaction.modelOverrides[\"\(modelKey)\"].\(field.rawValue) setting: \(jsString(value))") == true)
    }

    @Test("ordinary compaction setting reports invalid values even when a valid model override exists", arguments: fieldValueCases(invalidValues))
    func invalidOrdinary(_ field: CompactionTokenFieldCase, _ value: Double) {
        let manager = SettingsManager.inMemory(Settings(compaction: field.ordinary(value, modelOverrides: [modelKey: field.override(4096)])))
        let error = "Invalid compaction.\(field.rawValue) setting: \(jsString(value)). Expected a non-negative safe integer."
        #expect(thrownMessage { _ = try manager.getCompactionSettings() } == error)
        #expect(thrownMessage { _ = try manager.getCompactionSettings(model) } == error)
    }

    @Test("ordinary compaction setting reports non-finite runtime values", arguments: fieldValueCases(nonFiniteValues))
    func nonFiniteOrdinary(_ field: CompactionTokenFieldCase, _ value: Double) {
        let manager = SettingsManager.inMemory()
        manager.applyOverrides(Settings(compaction: field.ordinary(value)))
        let message = thrownMessage { _ = try manager.getCompactionSettings() }
        #expect(message?.contains("Invalid compaction.\(field.rawValue) setting: \(jsString(value))") == true)
    }

    @Test("accepts zero in ordinary settings and model overrides") func acceptsZero() throws {
        let manager = SettingsManager.inMemory(Settings(compaction: Settings.CompactionSettings(reserveTokens: 0, keepRecentTokens: 0)))
        #expect(try manager.getCompactionSettings(model) == CompactionSettings(enabled: true, reserveTokens: 0, keepRecentTokens: 0))
        manager.applyOverrides(Settings(compaction: Settings.CompactionSettings(
            reserveTokens: 1000,
            keepRecentTokens: 1000,
            modelOverrides: [modelKey: Settings.CompactionModelOverride(reserveTokens: 0, keepRecentTokens: 0)]
        )))
        #expect(try manager.getCompactionSettings(model) == CompactionSettings(enabled: true, reserveTokens: 0, keepRecentTokens: 0))
    }
}
