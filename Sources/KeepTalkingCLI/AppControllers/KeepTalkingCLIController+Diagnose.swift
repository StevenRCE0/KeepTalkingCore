import Foundation
import KeepTalkingSDK

extension KeepTalkingCLIController {
    /// Runs the SFU ICE connectivity probe, streams diagnostics to stdout,
    /// prints a one-line summary, then exits 0 on pass or 1 on failure.
    func runDiagnose() async {
        let config = cliConfig.sdkConfig
        print("--- SFU ICE Diagnostic ---")
        print("signal:      \(config.signalURL.absoluteString)")
        print("ice servers: \(config.sfuIceServers.joined(separator: ", "))")
        print("node:        \(config.node.uuidString.lowercased())")
        print("")

        let result = await diagnoseSFUICE(
            signalURL: config.signalURL,
            iceServers: config.sfuIceServers,
            timeoutSeconds: 30,
            onLog: { line in print(line) }
        )

        print("")
        print("--- Result ---")
        print(result.summary)

        Foundation.exit(result.succeeded ? 0 : 1)
    }
}
