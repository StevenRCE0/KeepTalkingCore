import Foundation

/// One section of the system prompt. A context style assembles an ordered
/// list of these for a turn and `AIPromptPresets.render` joins what they say,
/// so a style decides which sections exist, in what order, and which tools
/// the prose refers to.
public enum OrchestrationPromptFactor: Sendable, Equatable {
    /// Where a per-turn detail is spelled out: in the system prompt itself,
    /// or in the trailing turn-context row the orchestrated layout sends.
    public enum TurnDetailPlacement: Sendable, Equatable {
        case systemPrompt
        case turnContext
    }

    /// Whether the transcript is the whole conversation context or only its
    /// stable prefix, with the per-turn part left to the turn context.
    public enum ConversationContextScope: Sendable, Equatable {
        case whole
        case stablePrefix
    }

    case identity(opening: String)
    case environment(platform: String, currentDate: String, datePlacement: TurnDetailPlacement)
    case constitution
    case privacy
    case modelCapabilities(AIModelProfile, attachmentReader: String, searchThreads: String)
    case conversationOnly(AIModelProfile)
    case methodology
    case responseLanguages([String])
    case actionRouting(runAction: String, skillMetainfo: String)
    case threadMemory(searchThreads: String)
    case currentPromptAttachments(attachmentListing: String, attachmentReader: String, avoidAutomaticToolUse: Bool)
    case remoteNodePolicy
    case nodeTargeting
    case fileAccess(attachmentListing: String, attachmentReader: String, runAction: String)
    case skillPolicy(runAction: String, skillMetainfo: String)
    case toolResultPolicy
    case threadConsults(searchThreads: String)
    case sideNotes([KeepTalkingSideNoteDTO])
    case conversationContext(transcript: String, scope: ConversationContextScope)
    case threadAnnotation(markTurningPoint: String, markChitterChatter: String, liveTopic: TurnDetailPlacement)
}

extension OrchestrationPromptFactor {
    /// The group-chat context style: a participant among nodes, with thread
    /// memory, side notes and turning-point annotation. A model that cannot
    /// call tools gets only the conversation.
    public static func groupChat(
        tools: AIPromptToolNames,
        currentPromptIncludesAttachments: Bool = false,
        currentPromptShouldAvoidAutomaticToolUse: Bool = false,
        sideNotes: [KeepTalkingSideNoteDTO] = [],
        contextTranscript: String,
        currentDate: String,
        platform: String,
        responseLanguages: [String] = [],
        modelProfile: AIModelProfile? = nil,
        layout: AIPromptPresets.Layout = .legacy
    ) -> [OrchestrationPromptFactor] {
        let orchestrated = layout == .orchestrated
        let placement: TurnDetailPlacement = orchestrated ? .turnContext : .systemPrompt
        let scope: ConversationContextScope = orchestrated ? .stablePrefix : .whole
        var factors: [OrchestrationPromptFactor] = [
            .identity(opening: AIPromptPresets.groupChatIdentity),
            .environment(platform: platform, currentDate: currentDate, datePlacement: placement),
        ]
        if let modelProfile, !modelProfile.supportsToolCalling {
            factors += [
                .conversationOnly(modelProfile),
                .responseLanguages(responseLanguages),
                .privacy,
            ]
            if !orchestrated { factors.append(.sideNotes(sideNotes)) }
            factors.append(.conversationContext(transcript: contextTranscript, scope: scope))
            return factors
        }
        factors += [.constitution, .privacy]
        if let modelProfile {
            factors.append(
                .modelCapabilities(
                    modelProfile,
                    attachmentReader: tools[.attachmentReader],
                    searchThreads: tools[.searchThreads]
                )
            )
        }
        factors += [
            .methodology,
            .responseLanguages(responseLanguages),
            .actionRouting(runAction: tools[.runAction], skillMetainfo: tools[.skillMetainfo]),
            .threadMemory(searchThreads: tools[.searchThreads]),
        ]
        if !orchestrated, currentPromptIncludesAttachments {
            factors.append(
                .currentPromptAttachments(
                    attachmentListing: tools[.attachmentListing],
                    attachmentReader: tools[.attachmentReader],
                    avoidAutomaticToolUse: currentPromptShouldAvoidAutomaticToolUse
                )
            )
        }
        factors += [
            .remoteNodePolicy,
            .nodeTargeting,
            .fileAccess(
                attachmentListing: tools[.attachmentListing],
                attachmentReader: tools[.attachmentReader],
                runAction: tools[.runAction]
            ),
            .skillPolicy(runAction: tools[.runAction], skillMetainfo: tools[.skillMetainfo]),
            .toolResultPolicy,
        ]
        if orchestrated {
            factors.append(.threadConsults(searchThreads: tools[.searchThreads]))
        } else {
            factors.append(.sideNotes(sideNotes))
        }
        factors += [
            .conversationContext(transcript: contextTranscript, scope: scope),
            .threadAnnotation(
                markTurningPoint: tools[.markTurningPoint],
                markChitterChatter: tools[.markChitterChatter],
                liveTopic: placement
            ),
        ]
        return factors
    }
}
