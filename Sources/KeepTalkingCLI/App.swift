import Foundation

@main
struct KeepTalkingApp {
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        if PluginLabCommand.shouldHandle(argv) {
            await PluginLabCommand.run(Array(argv.dropFirst()))
            return
        }
        if BlobLabCommand.shouldHandle(argv) {
            await BlobLabCommand.run(Array(argv.dropFirst()))
            return
        }
        if QueryCommand.shouldHandle(argv) {
            await QueryCommand.run(argv)
            return
        }
        await KeepTalkingCLIController.main()
    }
}
