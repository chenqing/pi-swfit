import Foundation

// Port of packages/ai/src/model-catalog.ts
//
// The TS mapped catalog types (`ChatModelCatalog<TGroups, TProvider>` etc.) only exist for static typing;
// Swift catalogs are insertion-ordered maps from model id to model.

/// `Record<api, Record<key, model>>` in declaration order.
public typealias ModelGroups = [(api: String, models: [(key: String, model: AnyModel)])]

public typealias ChatModelCatalog = JSMap<Model>
public typealias ImageModelCatalog = JSMap<AnyModel>
public typealias ClassifierModelCatalog = JSMap<AnyModel>

private func flattenModelCatalog(_ groups: ModelGroups, _ type: ModelType) -> JSMap<AnyModel> {
    var catalog = JSMap<AnyModel>()
    for model in groups.flatMap({ $0.models.map(\.model) }) where model.type == type {
        catalog[model.id] = model
    }
    return catalog
}

public func flattenChatModelCatalog(_ provider: ProviderId, _ groups: ModelGroups) -> ChatModelCatalog {
    flattenModelCatalog(groups, "chat")
}

public func flattenImageModelCatalog(_ provider: ProviderId, _ groups: ModelGroups) -> ImageModelCatalog {
    flattenModelCatalog(groups, "image")
}

public func flattenClassifierModelCatalog(_ provider: ProviderId, _ groups: ModelGroups) -> ClassifierModelCatalog {
    flattenModelCatalog(groups, "classifier")
}

// MARK: - Swift-only helper

/// Insertion-ordered string-keyed map with JS `Map` semantics: re-setting an existing key keeps its
/// position; deleting then setting appends.
public struct JSMap<Value>: Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: Value] = [:]

    public init() {}

    public subscript(key: String) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public func has(_ key: String) -> Bool { storage[key] != nil }
    public var values: [Value] { keys.map { storage[$0]! } }
    public var entries: [(key: String, value: Value)] { keys.map { ($0, storage[$0]!) } }
    public mutating func removeAll() { keys = []; storage = [:] }

    public func makeIterator() -> IndexingIterator<[(key: String, value: Value)]> { entries.makeIterator() }
}

extension JSMap: Sendable where Value: Sendable {}
