import Foundation

// Port of utils/model-operations.ts
// Swift: the port has one `Model` struct (chat models); image and classifier models are not ported, so
// `AnyModel` is `Model` and `type` is its optional `"chat" | "image" | "classifier"` string.

/// `"chat" | "image" | "classifier"`
public typealias ModelType = String

/// The type of a model. Models without `type` are chat models.
public func getModelType(_ model: Model) -> ModelType {
    model.type ?? "chat"
}

/// Runtime-checked model type narrowing, including legacy chat models without `type`.
public func isModelType(_ model: Model, _ type: ModelType) -> Bool {
    getModelType(model) == type
}

public func assertChatModel(_ model: Model) throws {
    if !isModelType(model, "chat") {
        throw ModelsError(.provider, "Model \(model.provider)/\(model.id) is not a chat model")
    }
}

public func assertImageModel(_ model: Model) throws {
    if !isModelType(model, "image") {
        throw ModelsError(.provider, "Model \(model.provider)/\(model.id) is not an image model")
    }
}

public func assertClassifierModel(_ model: Model) throws {
    if !isModelType(model, "classifier") {
        throw ModelsError(.provider, "Model \(model.provider)/\(model.id) is not a classifier model")
    }
}

// Not ported: assertClassifierInputSupported, imageErrorResult, classifierErrorResult (image generation and
// classifier APIs, their context and result types are not part of the Swift port).
