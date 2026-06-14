import Foundation

/// The output of the skill planner: the **sandbox resource** a skill needs — the
/// scope (env vars, directories, files, network egress) plus parameters collected
/// during planning. There is NO per-operation command list and NO tool
/// declaration: skills execute through the single `kt_shell` op, and the seatbelt
/// boundary is derived from this scope + a fixed read/execute verb set
/// (`ScopeResolver.implicitDescriptor`), not from enumerated commands.
public struct KTSkillCommandPlan: Codable, Sendable {
    public var skillActionID: UUID
    public var skillName: String
    public var rationale: String
    public var requiredEnv: [String]
    public var requiredDirectories: [String]
    /// Labelled file keys the skill needs the user to point at (e.g. a script entry
    /// point, a config file). Distinct from `requiredDirectories` — the host opens
    /// a file picker, not a folder picker, when collecting these.
    public var requiredFiles: [String]
    /// RUNTIME network hosts: hosts the skill needs egress to when it EXECUTES
    /// (e.g. "api.github.com"). Distinct from `setupNetworkHosts`, which is only
    /// contacted while the planner provisions the environment.
    public var requiredNetworkHosts: [String]
    /// Subset of `requiredNetworkHosts` the user explicitly granted at plan time.
    public var grantedNetworkHosts: [String]
    /// SETUP-time network hosts: hosts a planner `kt_shell` command contacted to
    /// provision the env (install deps, fetch models). A SEPARATE consent from
    /// runtime egress — these are reached once, at plan time, not when the skill
    /// later runs.
    public var setupNetworkHosts: [String]
    /// Subset of `setupNetworkHosts` the user granted for the setup phase.
    public var grantedSetupNetworkHosts: [String]
    /// Parameters collected interactively during planning (env values, directory
    /// paths, file paths). Stored directly in the skill bundle's `parameters` dict.
    public var collectedParameters: [String: String]?

    public init(
        skillActionID: UUID,
        skillName: String,
        rationale: String,
        requiredEnv: [String] = [],
        requiredDirectories: [String] = [],
        requiredFiles: [String] = [],
        requiredNetworkHosts: [String] = [],
        grantedNetworkHosts: [String] = [],
        setupNetworkHosts: [String] = [],
        grantedSetupNetworkHosts: [String] = []
    ) {
        self.skillActionID = skillActionID
        self.skillName = skillName
        self.rationale = rationale
        self.requiredEnv = requiredEnv
        self.requiredDirectories = requiredDirectories
        self.requiredFiles = requiredFiles
        self.requiredNetworkHosts = requiredNetworkHosts
        self.grantedNetworkHosts = grantedNetworkHosts
        self.setupNetworkHosts = setupNetworkHosts
        self.grantedSetupNetworkHosts = grantedSetupNetworkHosts
        self.collectedParameters = nil
    }

    private enum CodingKeys: String, CodingKey {
        case skillActionID, skillName, rationale, requiredEnv, requiredDirectories,
            requiredFiles, requiredNetworkHosts, grantedNetworkHosts,
            setupNetworkHosts, grantedSetupNetworkHosts, collectedParameters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.skillActionID = try c.decode(UUID.self, forKey: .skillActionID)
        self.skillName = try c.decode(String.self, forKey: .skillName)
        self.rationale = try c.decode(String.self, forKey: .rationale)
        self.requiredEnv = (try? c.decode([String].self, forKey: .requiredEnv)) ?? []
        self.requiredDirectories = (try? c.decode([String].self, forKey: .requiredDirectories)) ?? []
        self.requiredFiles = (try? c.decode([String].self, forKey: .requiredFiles)) ?? []
        self.requiredNetworkHosts = (try? c.decode([String].self, forKey: .requiredNetworkHosts)) ?? []
        self.grantedNetworkHosts = (try? c.decode([String].self, forKey: .grantedNetworkHosts)) ?? []
        self.setupNetworkHosts = (try? c.decode([String].self, forKey: .setupNetworkHosts)) ?? []
        self.grantedSetupNetworkHosts = (try? c.decode([String].self, forKey: .grantedSetupNetworkHosts)) ?? []
        self.collectedParameters = try c.decodeIfPresent([String: String].self, forKey: .collectedParameters)
    }
}
