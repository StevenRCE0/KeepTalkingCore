import FluentKit
import SwiftUI

public enum FluentModelBindingError: Error {
    case missingModelID
    case modelNotFound
}

@MainActor
@dynamicMemberLookup
public final class FluentModelBinding<ModelType: FluentKit.Model>:
    ObservableObject
{
    public private(set) var model: ModelType
    private let database: any Database

    public init(model: ModelType, database: any Database) {
        self.model = model
        self.database = database
    }

    public subscript<Value>(
        dynamicMember keyPath: ReferenceWritableKeyPath<ModelType, Value>
    ) -> Binding<Value> {
        binding(keyPath)
    }

    public func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<ModelType, Value>
    ) -> Binding<Value> {
        Binding(
            get: { self.model[keyPath: keyPath] },
            set: { newValue in
                self.objectWillChange.send()
                self.model[keyPath: keyPath] = newValue
            }
        )
    }

    public func replaceModel(with model: ModelType) {
        self.model = model
        objectWillChange.send()
    }

    public func save() async throws {
        try await model.save(on: database)
    }

    @discardableResult
    public func refresh() async throws -> ModelType {
        guard let id = model.id else {
            throw FluentModelBindingError.missingModelID
        }
        guard let fresh = try await ModelType.find(id, on: database) else {
            throw FluentModelBindingError.modelNotFound
        }
        replaceModel(with: fresh)
        return fresh
    }
}

@MainActor
public extension FluentKit.Model {
    func swiftUIBinding(on database: any Database) -> FluentModelBinding<Self> {
        FluentModelBinding(model: self, database: database)
    }
}
