import Foundation
import KeepTalkingSDK

extension KeepTalkingCLIController {
    /// Runs the SFU ICE connectivity probe, streams diagnostics to stdout,
    /// prints a one-line summary, then exits 0 on pass or 1 on failure.
    func runDiagnose() async {
        print("Legacy ICE diagnostics were removed with the KeepTalkingSFU transport cutover.")
        print("Use `KeepTalking sfujuice --sfu host:port` or `KeepTalking bloblab ...` for current stack diagnostics.")
        Foundation.exit(0)
    }
}
