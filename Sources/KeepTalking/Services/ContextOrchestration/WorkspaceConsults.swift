import Foundation

struct WorkspaceConsultReply: Sendable, Decodable {
    let relevant: Bool?
    let facts: [String]?
    let elements: [String]?
}

struct WorkspaceConsultFinding: Sendable {
    let section: KeepTalkingWorkspaceSection
    var consulted = false
    var relevant = true
    var facts: [String] = []
    var elementIDs: [String] = []
    var failure: String?
}

extension ThreadConsultBrief {
    static func workspace(userMessage: AIMessage, liveTail: [AIMessage]) -> Self {
        Self(
            systemPrompt: workspaceSystemPrompt, liveTail: liveTail, question: userMessage, charter: workspaceCharter,
            label: "workspace")
    }

    static let workspaceSystemPrompt = """
        You read one shared workspace of a group conversation — a canvas, board or document rendered as text: elements as id — [label], the links between them, groups, what is visible and selected — for what the reply to the user's latest message needs. You never reply to the user and never call tools.
        Quote labels, ids, numbers and names exactly as written.
        """

    static let workspaceCharter = """
        Consultation — not the reply to the user. The workspace above is what everyone in the conversation sees right now. Report everything in it the reply to the user's latest message (just above) needs: the elements it concerns, how they connect, what is selected or visible, counts, and anything missing or inconsistent the message asks about. Use the recent conversation above it only to understand what the message refers to.
        Reply with ONLY a JSON object:
        {"relevant": true, "facts": ["…"], "elements": ["<element id>"]}
        - relevant: false when nothing in the workspace bears on the message; facts may then be empty.
        - facts: short, exact statements with labels and ids as written, so the reply can name and change those elements.
        - elements: the ids of the elements the facts concern.
        """
}

extension KeepTalkingClient {
    func consultWorkspaces(
        _ sections: [KeepTalkingWorkspaceSection],
        strategy: KeepTalkingOrchestrationStrategy,
        brief: ThreadConsultBrief,
        with consultant: ThreadConsultant
    ) async -> [WorkspaceConsultFinding] {
        guard !sections.isEmpty else { return [] }
        let consulted: [Bool] = sections.map {
            strategy.layout == .orchestrated && strategy.consultsWorkspaces
                && AIMessage.approximateTokens($0.snapshot.liftedText) >= strategy.workspaceConsultMinimumTokens
        }
        var findings = sections.map { WorkspaceConsultFinding(section: $0) }
        await withTaskGroup(of: (Int, WorkspaceConsultFinding).self) { group in
            for (index, section) in sections.enumerated() where consulted[index] {
                group.addTask {
                    (index, await self.workspaceConsultFinding(section, brief: brief, with: consultant))
                }
            }
            for await (index, finding) in group { findings[index] = finding }
        }
        return findings
    }

    private func workspaceConsultFinding(
        _ section: KeepTalkingWorkspaceSection, brief: ThreadConsultBrief, with consultant: ThreadConsultant
    ) async -> WorkspaceConsultFinding {
        var finding = WorkspaceConsultFinding(section: section, consulted: true)
        var configuration = consultant.configuration
        configuration.telemetry?.label = "workspace · \(section.manifest.title)"
        do {
            let turn = try await consultant.connector.completeTurn(
                messages: brief.messages(prefix: section.snapshot.liftedText),
                tools: [],
                model: consultant.model,
                toolChoice: nil,
                stage: .execution,
                configuration: configuration,
                toolExecutor: nil
            )
            if let usage = turn.usage {
                onLog?(
                    "[ai.usage] turn=\(configuration.telemetry?.agentTurnID?.uuidString.prefix(8) ?? "?") role=consult \(usage.logDescription)"
                )
            }
            guard let reply: WorkspaceConsultReply = Self.firstJSONObject(in: turn.assistantText ?? "") else {
                finding.failure = "unparseable reply"
                return finding
            }
            finding.relevant = reply.relevant ?? !(reply.facts ?? []).isEmpty
            finding.facts = reply.facts ?? []
            finding.elementIDs = reply.elements ?? []
        } catch {
            finding.failure = error.localizedDescription
        }
        return finding
    }

    static func workspaceSection(_ finding: WorkspaceConsultFinding, snapshotTool: String, mutateTool: String)
        -> String
    {
        let section = finding.section
        guard finding.consulted, finding.failure == nil else {
            return OrchestrationPromptFactor.workspace(section, snapshotTool: snapshotTool, mutateTool: mutateTool)
                .rendered
        }
        let manifest = section.manifest
        let writing =
            manifest.mutations.isEmpty
            ? "It is read-only for you."
            : "To change it, call \(mutateTool) with mutations in its own schema (the tool text says how); people see your edits at once."
        var lines = [
            "§ Workspace: \(manifest.title)",
            "Kind: \(manifest.kind.rawValue). Schema: \(manifest.schema). Stats: \(section.snapshot.stats.summaryLine).",
            "A consultant read the whole workspace as it is right now against this message; below is what the reply needs from it. For more of it, call \(snapshotTool) with schema \"\(manifest.schema)\" and a granularity. \(writing)",
        ]
        if finding.relevant, !finding.facts.isEmpty {
            lines.append(contentsOf: finding.facts.map { "- \($0)" })
            if !finding.elementIDs.isEmpty {
                lines.append("Elements concerned: \(finding.elementIDs.joined(separator: ", "))")
            }
        } else {
            lines.append("- nothing on it bears on this message.")
        }
        return lines.joined(separator: "\n")
    }
}
