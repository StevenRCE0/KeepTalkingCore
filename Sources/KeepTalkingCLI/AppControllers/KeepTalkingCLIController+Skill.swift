import Foundation
import KeepTalkingSDK

extension KeepTalkingCLIController {
    func runSkillManagementCommand(_ command: SkillManagementCommand) async throws {
        switch command {
            case .list:
                await listSkillActions()
            case .remove(let actionID):
                try await client.removeSkillAction(actionID: actionID)
                print("[skill] removed action=\(actionID.uuidString.lowercased())")
            case .addDirectory(let name, let directory, let description):
                try await registerDirectorySkillAction(
                    name: name,
                    directory: directory,
                    description: description ?? ""
                )
        }
    }

    func listSkillActions() async {
        do {
            let actions = try await client.listAvailableActions()
                .filter { $0.isSkill }
            if actions.isEmpty {
                print("[skill] none")
                return
            }

            print("[skill] total=\(actions.count)")
            for action in actions {
                print(
                    "- id=\(action.actionID.uuidString.lowercased()) name=\(action.name)"
                )
                if !action.description.isEmpty {
                    print("  desc=\(action.description)")
                }
            }
        } catch {
            fputs("List skill actions failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func removeSkillAction(actionIDRaw: String) async {
        let trimmedActionID = actionIDRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let actionID = UUID(uuidString: trimmedActionID) else {
            print("Invalid action UUID: \(trimmedActionID)")
            return
        }
        do {
            try await client.removeSkillAction(actionID: actionID)
            print("[skill] removed action=\(actionID.uuidString.lowercased())")
        } catch {
            fputs("Skill remove failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func registerDirectorySkillAction(
        name: String,
        directoryRaw: String,
        description: String
    ) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = directoryRaw.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedName.isEmpty, !trimmedDirectory.isEmpty else {
            print("Usage: /skill add directory <name> <path> [description]")
            return
        }

        let expanded = NSString(string: trimmedDirectory).expandingTildeInPath
        let directory = URL(fileURLWithPath: expanded)

        do {
            try await registerDirectorySkillAction(
                name: trimmedName,
                directory: directory,
                description: description
            )
        } catch {
            fputs("Skill registration failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func registerDirectorySkillAction(
        name: String,
        directory: URL,
        description: String
    ) async throws {
        let trimmedDescription = description.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let indexDescription =
            trimmedDescription.isEmpty
            ? "Skill directory: \(name)"
            : trimmedDescription

        let action = try await client.registerAction(
            payload: .skill(KeepTalkingSkillBundle(
                name: name,
                indexDescription: indexDescription,
                directory: directory
            ))
        )
        let actionID = action.id?.uuidString.lowercased() ?? "unknown"
        print(
            "[skill] registered action=\(actionID) name=\(name) directory=\(directory.path)"
        )
    }
}
