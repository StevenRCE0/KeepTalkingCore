import Foundation

nonisolated enum SemanticIndexTrace {
    static func info(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[SemanticIndex] \(message())")
        #endif
    }

    static func error(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[SemanticIndex][error] \(message())")
        #endif
    }
}
