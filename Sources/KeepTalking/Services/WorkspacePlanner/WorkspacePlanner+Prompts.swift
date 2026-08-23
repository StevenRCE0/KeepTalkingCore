//
//  WorkspacePlanner+Prompts.swift
//  KeepTalking
//
//  System / user / continuation prompts for the workspace planner.
//

import Foundation

extension KeepTalkingWorkspacePlanner {

    func makeSystemPrompt(
        existingActions: [WorkspacePlannerExistingAction],
        existingTags: [String],
        targetContext: String? = nil
    ) -> String {
        let contextInstruction: String
        if let targetContext {
            contextInstruction =
                "This plan targets the EXISTING context \"\(targetContext)\" — the "
                + "workspace is planned INTO it, not created fresh. Call "
                + "kt_propose_context exactly once with that exact name (refine only "
                + "the description); every tag, action and note applies to that context."
        } else {
            contextInstruction =
                "Every plan proposes exactly one, with a short, concrete name (not "
                + "the user's prompt verbatim)."
        }
        let inventory: String
        if existingActions.isEmpty {
            inventory = "(none — the user has no actions yet)"
        } else {
            inventory =
                existingActions
                .map { "- \($0.id.uuidString): \($0.name) — \($0.indexDescription)" }
                .joined(separator: "\n")
        }
        let tagVocabulary: String
        if existingTags.isEmpty {
            tagVocabulary = "(none yet — this is the user's first tagged workspace)"
        } else {
            tagVocabulary = existingTags.joined(separator: ", ")
        }

        return """
            You are the workspace planner for KeepTalking, a P2P AI conversation \
            platform. The user describes what they're working on; you decompose that \
            intent into a WORKSPACE PLAN made of these atoms:

            - CONTEXT: one shared conversation container the work lives in. \
            \(contextInstruction)
            - TAGS: labels applied to the context for retrieval and filtering. SELECT \
            from the user's existing vocabulary below — tags are shared across their \
            workspaces, and a synonym of an existing tag fragments retrieval. Propose a \
            NEW tag only when nothing in the vocabulary fits the topic, and keep it a \
            lowercase single word or short slug. 2–4 total.
            - ACTIONS: capabilities the workspace needs. Every proposal is a SPEC \
            another agent builds from without further context — one sentence stating \
            what the action does, what input it takes, and what it produces or \
            affects. "Fetches new arXiv papers matching given topic filters and \
            returns title, abstract and PDF link" — never "helps with papers". Three \
            sources:
              1. EXISTING — an action from the user's inventory below. Always prefer \
            slotting an existing action over proposing a new one when it covers the need.
              2. CREATE — a new action the user's own agent will build afterwards \
            (skills, primitives, MCP connections). The name + description are handed \
            verbatim to that build flow as its instructions.
              3. PEER — an action expected from another person's agent. You cannot name \
            real people: open a GHOST PEER slot instead and reference it by alias. The \
            description travels with the invitation — the peer's agent builds from it \
            with no other context, so it must be precise about what is created, what \
            it accesses on the peer's side, and what gets granted back.
            - GHOST PEERS: placeholder role slots with two sides: \
            expected_capabilities — action names the peer PROVIDES (incoming, from your \
            kt_propose_peer_action calls); and GRANTS — local actions you share WITH \
            the peer (outgoing, via kt_grant_to_peer). The alias names the ROLE \
            concretely ("arXiv access provider", not "Helper"); each expected \
            capability is an exact action name from your peer-action proposals. The \
            user binds each slot to a real node; binding triggers both the incoming \
            requests and the outgoing grants. Open one when the workspace needs \
            another person's capability, or when you need to share yours.
            - SIDE NOTES: short SOP / workflow notes attached to the context that guide \
            the agent's future behaviour in it (e.g. a weekly cadence, a review \
            checklist). Key is a short slug; value is the note text.

            User's existing actions:
            \(inventory)

            User's existing tags:
            \(tagVocabulary)

            Rules:
            - Call tools to record every atom; prose replies are not rendered.
            - Ask with kt_ask_user when the intent is ambiguous or a detail materially \
            changes the plan (cadence, scope, who else is involved). Prefer one good \
            question over guessing; don't interrogate.
            - Use web_search when current facts would improve the plan (a service's \
            capabilities, a data source's shape) and it is available.
            - Keep plans minimal: only atoms the stated intent needs. No speculative \
            actions, no filler tags, no empty ghost slots.
            - When revising after user feedback, adjust only what changed — atoms you \
            re-propose with the same identity (action name+source, ghost alias, note \
            key) keep their identity.
            - Decline with kt_refuse (category "too_broad") when the request is not a \
            workspace ("control my whole computer"), or (category "blocked") when \
            critical information is still missing after asking.
            - Finish with kt_finalize and a one-sentence rationale once the plan is \
            complete.
            """
    }

    func makeUserPrompt(intent: String) -> String {
        """
        The user describes what they're up to:

        \(intent)

        Decompose this into a workspace plan. Slot existing actions where they fit, \
        propose what's missing, open ghost peer slots for capabilities another \
        person's agent must provide, and attach any SOP the workflow implies. Ask \
        follow-up questions if something material is unclear, then finalize.
        """
    }

    func makeContinuationPrompt(_ message: String) -> String {
        """
        The user replied:

        \(message)

        Revise the plan accordingly — record only the changes (atoms you re-propose \
        with the same identity are updated in place, new ones are added). Remove \
        nothing unless the user asked. Then call kt_finalize again.
        """
    }
}
