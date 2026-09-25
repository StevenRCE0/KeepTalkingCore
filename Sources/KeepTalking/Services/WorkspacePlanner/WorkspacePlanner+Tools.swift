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

            makePeerTool(),

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
                    "kind": (.string, "One of: \"action\", \"peer\", \"tag\", \"side_note\"."),
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

    // MARK: - Peer tool (complex schema — built directly)

    private func makePeerTool() -> KeepTalkingActionToolDefinition {
        let actionItemSchema: AIProxyJSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Capability name for a NEW proposed action, e.g. 'arXiv Monitor'."
                    ),
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string(
                        "One-sentence spec: what the action does, its input, its output/effect. "
                            + "For a ghost peer this travels with the invitation — the peer's agent "
                            + "builds from it with no other context. For self this seeds the build flow."
                    ),
                ]),
                "action_id": .object([
                    "type": .string("string"),
                    "description": .string(
                        "UUID of an EXISTING action from the inventory. "
                            + "For self: slots it into the workspace. "
                            + "For a ghost peer: grants it to the peer."
                    ),
                ]),
            ]),
        ])
        let parameters: [String: AIProxyJSONValue] = [
            "type": .string("object"),
            "properties": .object([
                "alias": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Concrete role name. For a ghost peer, name the ROLE "
                            + "('arXiv access provider', not 'Helper'). For self, use 'self'."
                    ),
                ]),
                "self": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "True when the actions should be built/slotted by the LOCAL agent "
                            + "rather than expected from a ghost peer. Proposed actions become "
                            + "CREATE slots; existing IDs are slotted directly. Omit or false "
                            + "for a ghost peer."
                    ),
                ]),
                "actions": .object([
                    "type": .string("array"),
                    "description": .string(
                        "Actions associated with this peer. Each item is EITHER a proposed "
                            + "action {name, description} OR an existing action {action_id} — "
                            + "never both in the same item."
                    ),
                    "items": actionItemSchema,
                ]),
            ]),
            "required": .array([.string("alias"), .string("actions")]),
        ]
        return .init(
            functionName: Self.proposePeerTool,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description:
                "Propose a peer and its actions in one call. Two modes: (1) self=true — "
                + "the LOCAL agent's own capabilities for this workspace; proposed actions "
                + "become CREATE slots the agent builds afterwards, existing action_ids are "
                + "slotted from inventory. (2) self omitted or false — a GHOST PEER slot "
                + "(a role another person's node will be bound to); proposed actions are "
                + "capabilities that MUST live on the peer's machine (their data, hardware, "
                + "accounts), and existing action_ids are LOCAL actions GRANTED to the peer. "
                + "Default to self=true for any work the local agent can do — only open a "
                + "ghost peer when the capability genuinely requires another person's "
                + "environment. Re-proposing the same alias updates it.",
            parameters: parameters
        )
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
