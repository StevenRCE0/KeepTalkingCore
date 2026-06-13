import Foundation
import Testing

@testable import KeepTalkingSDK

/// Pure-model coverage for the planner redesign: the single categorised decline
/// (`kt_refuse` with a `category`) and the setup-vs-runtime network split on the
/// plan + bundle. No LLM/agent loop is exercised — these guard the data contract
/// the planner produces and the host persists.
struct SkillPlannerModelTests {

    // MARK: - Decline categorisation (merged reject/refuse)

    @Test("decline category maps the agent's free-form string to a known kind")
    func declineKindMapsRawCategory() {
        #expect(KeepTalkingSkillPlannerDeclineKind(rawCategory: "too_broad") == .tooBroad)
        #expect(KeepTalkingSkillPlannerDeclineKind(rawCategory: "TOO_BROAD") == .tooBroad)
        #expect(KeepTalkingSkillPlannerDeclineKind(rawCategory: "too-broad") == .tooBroad)
        #expect(KeepTalkingSkillPlannerDeclineKind(rawCategory: "rejected") == .tooBroad)
        #expect(KeepTalkingSkillPlannerDeclineKind(rawCategory: "blocked") == .blocked)
        // Unknown / missing categories fall back to the safe, recoverable kind.
        #expect(KeepTalkingSkillPlannerDeclineKind(rawCategory: nil) == .blocked)
        #expect(KeepTalkingSkillPlannerDeclineKind(rawCategory: "") == .blocked)
        #expect(KeepTalkingSkillPlannerDeclineKind(rawCategory: "nonsense") == .blocked)
    }

    // MARK: - Plan network split round-trips

    @Test("KTSkillCommandPlan round-trips setup + runtime network separately")
    func planEncodesSetupAndRuntimeNetworkDistinctly() throws {
        var plan = KTSkillCommandPlan(
            skillActionID: UUID(),
            skillName: "Deps Installer",
            rationale: "test",
            requiredNetworkHosts: ["api.github.com"],
            grantedNetworkHosts: ["api.github.com"],
            setupNetworkHosts: ["pypi.org", "files.pythonhosted.org"],
            grantedSetupNetworkHosts: ["pypi.org"]
        )
        plan.collectedParameters = ["PROJECT_ROOT": "/tmp/proj"]

        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(KTSkillCommandPlan.self, from: data)

        #expect(decoded.requiredNetworkHosts == ["api.github.com"])
        #expect(decoded.grantedNetworkHosts == ["api.github.com"])
        #expect(decoded.setupNetworkHosts == ["pypi.org", "files.pythonhosted.org"])
        #expect(decoded.grantedSetupNetworkHosts == ["pypi.org"])
    }

    @Test("KTSkillCommandPlan decodes legacy JSON without setup-network keys")
    func planDecodesWithoutSetupNetworkKeys() throws {
        // A plan persisted before the split has no setup-network fields.
        let legacy = """
            {"skillActionID":"\(UUID().uuidString)","skillName":"Old",
             "rationale":"r","requiredNetworkHosts":["x.com"],"grantedNetworkHosts":[]}
            """
        let decoded = try JSONDecoder().decode(
            KTSkillCommandPlan.self, from: Data(legacy.utf8))
        #expect(decoded.requiredNetworkHosts == ["x.com"])
        #expect(decoded.setupNetworkHosts.isEmpty)
        #expect(decoded.grantedSetupNetworkHosts.isEmpty)
    }

    // MARK: - Bundle network split round-trips

    @Test("KeepTalkingSkillBundle round-trips setup + runtime network separately")
    func bundleEncodesSetupAndRuntimeNetworkDistinctly() throws {
        let bundle = KeepTalkingSkillBundle(
            name: "S", indexDescription: "d", toolsAnalysed: true,
            requiredNetworkHosts: ["api.github.com"],
            grantedNetworkHosts: ["api.github.com"],
            setupNetworkHosts: ["pypi.org"],
            grantedSetupNetworkHosts: ["pypi.org"]
        )
        let data = try JSONEncoder().encode(bundle)
        let decoded = try JSONDecoder().decode(KeepTalkingSkillBundle.self, from: data)

        #expect(decoded.requiredNetworkHosts == ["api.github.com"])
        #expect(decoded.setupNetworkHosts == ["pypi.org"])
        #expect(decoded.grantedSetupNetworkHosts == ["pypi.org"])
    }

    @Test("KeepTalkingSkillBundle decodes legacy JSON without setup-network keys")
    func bundleDecodesWithoutSetupNetworkKeys() throws {
        let legacy = """
            {"id":"\(UUID().uuidString)","name":"Old","indexDescription":"d",
             "parameters":{},"toolsAnalysed":true,"requiredEnv":[],
             "requiredDirectories":[],"requiredFiles":[],
             "requiredNetworkHosts":["x.com"],"grantedNetworkHosts":[]}
            """
        let decoded = try JSONDecoder().decode(
            KeepTalkingSkillBundle.self, from: Data(legacy.utf8))
        #expect(decoded.requiredNetworkHosts == ["x.com"])
        #expect(decoded.setupNetworkHosts.isEmpty)
        #expect(decoded.grantedSetupNetworkHosts.isEmpty)
    }
}
