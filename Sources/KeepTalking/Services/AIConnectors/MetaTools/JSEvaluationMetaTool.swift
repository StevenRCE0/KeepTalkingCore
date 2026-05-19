import AIProxy
import Foundation
import MCP

extension KeepTalkingClient {
    func executeEvaluateJSToolCall(
        rawArguments: String
    ) async throws -> String {
        let args = (try? decodeToolArguments(rawArguments)) ?? [:]
        guard
            let code = args["code"]?.stringValue,
            !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return jsonString([
                "ok": false,
                "error": "code is required.",
            ])
        }

        guard let runtime = jsRuntime else {
            onLog?("[evaluate-js] no runtime configured")
            return jsonString([
                "ok": false,
                "error": KeepTalkingJSRuntimeError.runtimeNotConfigured
                    .errorDescription ?? "JS runtime not configured.",
            ])
        }

        let options = KeepTalkingJSEvaluationOptions()
        let result: KeepTalkingJSEvaluationResult
        do {
            result = try await runtime.evaluate(code, options: options)
        } catch {
            onLog?(
                "[evaluate-js] runtime threw error=\(error.localizedDescription)"
            )
            return jsonString([
                "ok": false,
                "error": error.localizedDescription,
            ])
        }

        var payload: [String: Any] = [
            "ok": !result.isError,
            "value": result.value,
            "console": result.consoleOutput,
        ]
        if result.isError, let message = result.errorMessage {
            payload["error"] = message
        }
        if result.truncated {
            payload["truncated"] = true
        }
        return jsonString(payload)
    }
}
