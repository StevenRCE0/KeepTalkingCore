//
//  WorkspacePlanner+Tools.swift
//  KeepTalking
//
//  The tool list handed to the model each turn. Mirrors the skill planner's
//  schema builder; `web_search` is appended only when a provider is available.
//

import AIProxy
import Foundation

extension KeepTalkingWorkspacePlanner {

    func makePlannerTools() -> [KeepTalkingActionToolDefinition] {
        var tools: [KeepTalkingActionToolDefinition] = [
            tool(
                name: Self.proposeContextTool,
                description:
                    "Propose the workspace's context. Exactly one per plan — calling again replaces it. The name is a short, concrete label, NOT the user's prompt verbatim.",
                properties: [
                    "name": (.string, "Short context name, e.g. 'ML Paper Reviews'."),
                    "description": (.string, "One-sentence description of what happens in this context."),
                ],
                required: ["name"]),

            tool(
                name: Self.proposeTagsTool,
                description:
                    "Apply tags to the context. SELECT from the user's existing tag vocabulary (listed in the system prompt) — a synonym of an existing tag fragments retrieval. Only when nothing existing fits, propose a new lowercase single word or short slug. 2–4 total. Calling again appends (duplicates ignored); the result reports which values matched the vocabulary.",
                properties: [
                    "tags": (.array, "Tag values, preferably drawn verbatim from the existing vocabulary.")
                ],
                required: ["tags"]),

            tool(
                name: Self.proposeGhostPeerTool,
                description:
                    "Open a ghost peer slot — a placeholder ROLE (not a real person) another node will later be bound to. Use only when the workspace needs a capability someone else's agent must provide. The alias names the role CONCRETELY ('arXiv access provider', not 'Helper'); expected_capabilities are the EXACT action names you propose via kt_propose_peer_action — the binding UI matches candidate nodes against them, so vague entries make every candidate look wrong. Re-proposing the same alias updates its capabilities.",
                properties: [
                    "alias": (.string, "Concrete role alias, e.g. 'arXiv access provider'."),
                    "expected_capabilities": (
                        .array,
                        "Exact action names this role provides — each must match a kt_propose_peer_action name, e.g. [\"arXiv Monitor\"]."
                    ),
                ],
                required: ["alias"]),

            tool(
                name: Self.useExistingActionTool,
                description:
                    "Slot one of the user's EXISTING actions into the workspace. Pass the exact id from the inventory.",
                properties: [
                    "action_id": (.string, "UUID from the existing-actions inventory."),
                    "name": (.string, "The action's name, for display."),
                ],
                required: ["action_id", "name"]),

            tool(
                name: Self.proposeNewActionTool,
                description:
                    "Propose an action the user's own agent should CREATE after setup (a skill, primitive, or MCP connection). The name + description are handed VERBATIM to the build flow as its only instructions — write a spec: what the action does, what input it takes, what it produces or affects. 'Extracts key findings and citations from a given PDF and returns a structured summary', never 'handles PDFs'.",
                properties: [
                    "name": (.string, "Capability name, e.g. 'PDF Extract'."),
                    "description": (
                        .string,
                        "One-sentence spec: what it does, its input, its output/effect. This is the build instruction."
                    ),
                ],
                required: ["name", "description"]),

            tool(
                name: Self.proposePeerActionTool,
                description:
                    "Propose an action expected FROM a ghost peer's agent (created and granted on their side once the slot is bound). The description travels with the invitation and the peer's agent builds from it with NO other context — state precisely what gets created, what it accesses on the peer's side, and what is granted back to this workspace. 'Monitors arXiv cs.LG for new submissions matching the workspace's topic filters and grants this context a fetch action returning title, abstract and PDF link' — never 'shares papers'. Reference the ghost by alias — it is auto-created if you haven't proposed it yet.",
                properties: [
                    "name": (.string, "Capability name, e.g. 'arXiv Monitor'."),
                    "description": (
                        .string,
                        "One-sentence spec written FOR the peer's agent: what it creates, what it accesses on their side, what is granted back."
                    ),
                    "ghost_alias": (.string, "Alias of the ghost peer slot expected to provide it."),
                ],
                required: ["name", "description", "ghost_alias"]),

            tool(
                name: Self.grantToPeerTool,
                description:
                    "Grant one of the workspace's LOCAL actions (existing or to-create) TO a ghost peer — when the slot is bound, the peer's agent can invoke it. Use to share the workspace's capabilities outward: 'I need them to run my PDF Extract'. Only local actions (existing, create) can be granted; peer-sourced actions cannot be re-granted.",
                properties: [
                    "action_name": (
                        .string,
                        "Name of an action proposed via kt_use_existing_action or kt_propose_new_action."
                    ),
                    "ghost_alias": (.string, "Alias of the ghost peer slot to grant it to."),
                ],
                required: ["action_name", "ghost_alias"]),

            tool(
                name: Self.proposeSideNoteTool,
                description:
                    "Attach an SOP / workflow side note to the context — guidance the agent follows in future turns (cadence, checklist, conventions). Re-proposing the same key replaces its value.",
                properties: [
                    "key": (.string, "Short slug, e.g. 'weekly-workflow'."),
                    "value": (.string, "The note text. Keep it under a short paragraph."),
                ],
                required: ["key", "value"]),

            tool(
                name: Self.removeTool,
                description:
                    "Remove a previously proposed atom when the user asked for it to go. Identity: action name, ghost alias, tag value, or side-note key.",
                properties: [
                    "kind": (.string, "One of: \"action\", \"ghost_peer\", \"tag\", \"side_note\"."),
                    "identity": (.string, "The atom's identity (name / alias / value / key)."),
                ],
                required: ["kind", "identity"]),

            tool(
                name: Self.askUserTool,
                description:
                    "Ask the user one free-form clarifying question when intent is ambiguous or a detail materially changes the plan. Prefer this over guessing; don't interrogate.",
                properties: [
                    "question": (.string, "The question, in plain language."),
                    "context": (
                        .string,
                        "Optional one-sentence context shown alongside so the user knows why you're asking."
                    ),
                ],
                required: ["question"]),

            tool(
                name: Self.refuseTool,
                description:
                    "Decline to plan. `category`: \"blocked\" — critical information is still missing after asking; \"too_broad\" — the request isn't a scoped workspace and shouldn't be built as stated. Terminating — do NOT call any other tool after.",
                properties: [
                    "category": (
                        .string,
                        "\"blocked\" or \"too_broad\". Defaults to \"blocked\"."
                    ),
                    "reason": (
                        .string,
                        "One-paragraph explanation shown verbatim, including what would unblock or an acceptable narrower version."
                    ),
                ],
                required: ["reason"]),

            tool(
                name: Self.finalizeTool,
                description:
                    "Finalize the plan. MUST be called once — after every atom is recorded. Requires a context to have been proposed.",
                properties: [
                    "rationale": (.string, "One-sentence summary of the workspace and why this shape fits.")
                ],
                required: ["rationale"]),
        ]
        if webSearchProvider != nil {
            tools.append(KeepTalkingClient.makeWebSearchTool())
        }
        return tools
    }

    // MARK: - Tool builder

    private enum ParamType { case string, array }

    private func tool(
        name: String, description: String,
        properties: [String: (ParamType, String)],
        required: [String]
    ) -> KeepTalkingActionToolDefinition {
        let schemaProps: [String: AIProxyJSONValue] = properties.mapValues { (type, desc) in
            switch type {
                case .string:
                    return .object([
                        "type": .string("string"),
                        "description": .string(desc),
                    ])
                case .array:
                    return .object([
                        "type": .string("array"),
                        "description": .string(desc),
                        "items": .object(["type": .string("string")]),
                    ])
            }
        }
        let parameters: [String: AIProxyJSONValue] = [
            "type": .string("object"),
            "properties": .object(schemaProps),
            "required": .array(required.map(AIProxyJSONValue.string)),
        ]
        return .init(
            functionName: name,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description: description,
            parameters: parameters
        )
    }
}
