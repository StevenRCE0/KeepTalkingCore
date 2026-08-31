import Crypto
import Foundation

extension UUID {
    /// A deterministic, human-friendly name for this UUID — `"Amber Swift Koala"`.
    ///
    /// This is the ONE name a UUID has. It is what the UI shows when a node,
    /// context, or thread has no user-chosen alias, and it is what an agent
    /// types back to reference an action. Both uses want the same thing: a
    /// short handle a human or a model can copy without corrupting it.
    ///
    /// Three words, not two. As a label, two would do; as an identifier it
    /// would not — 256² is 65,536, which at a few hundred objects gives a real
    /// chance of two sharing a name, and a collision in something an agent
    /// dispatches on is a correctness bug rather than a cosmetic one. Three
    /// words is 256³ ≈ 16.7M.
    ///
    /// Words rather than hex because hex has no redundancy: one wrong nibble in
    /// a UUID yields a well-formed id that simply does not exist, and the
    /// failure is indistinguishable from the object being gone. That happened —
    /// an agent turned `946e` into `946b`, got `unknown_action_id`, and
    /// reported that the host had crashed. Every word here is at least two
    /// edits from every other in its list, so a mistyped word is recognisably
    /// wrong AND repairable to exactly one candidate.
    ///
    /// Stable forever: a pure function of the id, with no storage and no
    /// migration.
    public var friendlyName: String {
        UUIDFriendlyName.name(for: friendlyNameCode)
    }

    /// `friendlyName` reduced to its matching form, `"amber-swift-koala"` —
    /// lowercase and hyphenated. Compare against this rather than the display
    /// string so case and separator differences never matter.
    public var friendlyNameToken: String {
        UUIDFriendlyName.token(for: friendlyNameCode)
    }

    /// The 24-bit code this UUID's name encodes.
    ///
    /// This is the lossy step, and the only one: 128 bits do not fit in 24, so
    /// two UUIDs can in principle share a code (see `UUIDFriendlyName.Code` for
    /// the odds). Everything downstream of it is exact — a code and a name are
    /// the same value in two spellings. Two objects share a name **iff** they
    /// share a code, which makes this the thing to store, index, or compare on
    /// when you care about name identity.
    public var friendlyNameCode: UUIDFriendlyName.Code {
        UUIDFriendlyName.code(for: self)
    }
}

// MARK: - Derivation, encoding, and matching

public enum UUIDFriendlyName {

    /// A name in its numeric form: three word indices packed into 24 bits.
    ///
    /// `Code` and the printed name are two spellings of one value, and
    /// converting between them loses nothing in either direction —
    /// `Code(name:)` inverts `name(for:)` exactly for all 16,777,216 values.
    /// Only `code(for: UUID)` discards information, which is unavoidable: it is
    /// the hash.
    public struct Code: Hashable, Sendable, CustomStringConvertible {
        /// Number of distinct names — 256³.
        public static let space = 256 * 256 * 256

        /// `0 ..< space`.
        public let rawValue: Int

        /// Fails for a value outside `0 ..< space`.
        public init?(rawValue: Int) {
            guard (0..<Self.space).contains(rawValue) else { return nil }
            self.rawValue = rawValue
        }

        init(unchecked rawValue: Int) {
            self.rawValue = rawValue
        }

        /// Builds a code from three word indices, each `0 ..< 256`.
        public init?(first: Int, second: Int, third: Int) {
            guard (0..<256).contains(first), (0..<256).contains(second),
                (0..<256).contains(third)
            else { return nil }
            self.rawValue = (first << 16) | (second << 8) | third
        }

        /// Parses a printed name back to its code — the exact inverse of
        /// `UUIDFriendlyName.name(for:)`. Accepts either spelling
        /// ("Amber Swift Koala" or "amber-swift-koala"), any case, and
        /// `-`/`_`/space/`.` between words. Returns nil if the words are not
        /// all in their lists, which is the point: a corrupted name is
        /// *detectably* corrupt rather than silently decoding to something.
        public init?(name: String) {
            guard let normalized = UUIDFriendlyName.normalize(name) else { return nil }
            let words = normalized.split(separator: "-").map(String.init)
            guard words.count == 3,
                let first = UUIDFriendlyName.adjectiveIndex[words[0]],
                let second = UUIDFriendlyName.adjectiveIndex[words[1]],
                let third = UUIDFriendlyName.nounIndex[words[2]]
            else { return nil }
            self.init(unchecked: (first << 16) | (second << 8) | third)
        }

        public var wordIndices: (first: Int, second: Int, third: Int) {
            ((rawValue >> 16) & 0xFF, (rawValue >> 8) & 0xFF, rawValue & 0xFF)
        }

        /// The display spelling, `"Amber Swift Koala"`.
        public var name: String { UUIDFriendlyName.name(for: self) }

        /// The matching spelling, `"amber-swift-koala"`.
        public var token: String { UUIDFriendlyName.token(for: self) }

        public var description: String { name }
    }

    // MARK: Converting

    /// The code for `id`. **This is the lossy step** — see `Code`.
    ///
    /// Derived from a SHA-256 of the id's bytes, never the bytes themselves.
    /// KeepTalking mints **v7** UUIDs, whose leading 48 bits are a millisecond
    /// timestamp — the previous implementation indexed straight into those
    /// bytes, so the adjective only changed every 49.7 days and the noun cycled
    /// every 4.66 hours. Measured on 220 real ids, that collapsed 220 objects
    /// into 165 names, with one name shared by 15 of them. Hashing decorrelates
    /// the timestamp and restores the full space; the same 220 ids now yield
    /// 220 distinct names.
    public static func code(for id: UUID) -> Code {
        let digest = Array(SHA256.hash(data: Data(withUnsafeBytes(of: id.uuid) { Array($0) })))
        return Code(unchecked: (Int(digest[0]) << 16) | (Int(digest[1]) << 8) | Int(digest[2]))
    }

    /// The display spelling of `code`. Exactly inverted by `Code(name:)`.
    public static func name(for code: Code) -> String {
        let (first, second, third) = code.wordIndices
        return [adjectives[first], adjectives[second], nouns[third]]
            .map(\.capitalized)
            .joined(separator: " ")
    }

    /// The matching spelling of `code`. Exactly inverted by `Code(name:)`.
    public static func token(for code: Code) -> String {
        let (first, second, third) = code.wordIndices
        return [adjectives[first], adjectives[second], nouns[third]]
            .joined(separator: "-")
    }

    // MARK: Resolving a name someone typed back

    /// What a caller-supplied token turned out to mean — the shared
    /// `KTFuzzyResolution` vocabulary, same shape the hex-handle resolver
    /// (`KTResourceManifest.resolveAgentHandle(_:among:)`) answers with.
    public typealias Resolution = KTFuzzyResolution<UUID>

    /// Interprets `token` as a friendly name or a raw UUID and matches it
    /// against `candidates`.
    ///
    /// A UUID must match exactly — hex has no redundancy, so guessing there
    /// would mean silently dispatching a different object. A name is decoded
    /// exactly first, then repaired word-by-word against the nearest list entry.
    public static func resolve(_ token: String, among candidates: [UUID]) -> Resolution {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        if let id = UUID(uuidString: trimmed) {
            return candidates.contains(id) ? .resolved(id) : .unknown
        }
        guard let normalized = normalize(trimmed) else { return .unknown }

        // Exact decode — compare codes, not strings, so spelling never matters.
        if let code = Code(name: normalized) {
            let exact = candidates.filter { $0.friendlyNameCode == code }
            if exact.count == 1 { return .resolved(exact[0]) }
            if exact.count > 1 { return .ambiguous(exact) }
            return .unknown
        }

        // Not a decodable name: repair each word, then decode again.
        let spoken = normalized.split(separator: "-").map(String.init)
        guard spoken.count == 3 else { return .unknown }
        let repaired = [
            nearestWord(to: spoken[0], in: adjectives) ?? spoken[0],
            nearestWord(to: spoken[1], in: adjectives) ?? spoken[1],
            nearestWord(to: spoken[2], in: nouns) ?? spoken[2],
        ].joined(separator: "-")
        guard repaired != normalized, let code = Code(name: repaired) else { return .unknown }

        let near = candidates.filter { $0.friendlyNameCode == code }
        if near.count == 1 { return .corrected(near[0], from: normalized, to: repaired) }
        return near.isEmpty ? .unknown : .ambiguous(near)
    }

    /// Lowercases and accepts `-`, `_`, space, or `.` between words, so the
    /// difference between "Amber Swift Koala" and "amber-swift-koala" — or an
    /// agent's formatting habits — never becomes a failure.
    public static func normalize(_ token: String) -> String? {
        let parts = token.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " || $0 == "." })
            .map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts.joined(separator: "-")
    }

    /// The list word within one edit of `candidate`, when exactly one qualifies.
    ///
    /// Every list word is ≥2 edits from every other. That is enough to DETECT any
    /// single typo, but not always to correct one: a mangled word can sit one edit
    /// from two list words that are themselves two apart (correcting every single
    /// edit would need a minimum distance of 3). Measured on the current lists,
    /// ~0.4% of single substitutions tie like that. A tie returns nil — refusing,
    /// rather than sending the caller to a different object — as does a
    /// two-edit mangling.
    static func nearestWord(to candidate: String, in list: [String]) -> String? {
        if list.contains(candidate) { return candidate }
        var found: String?
        for word in list where isWithinOneEdit(word, candidate) {
            if found != nil { return nil }
            found = word
        }
        return found
    }

    /// Levenshtein distance ≤ 1, without building a matrix.
    static func isWithinOneEdit(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a)
        let y = Array(b)
        if abs(x.count - y.count) > 1 { return false }
        if x.count == y.count {
            return zip(x, y).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) } == 1
        }
        let (short, long) = x.count < y.count ? (x, y) : (y, x)
        var i = 0
        while i < short.count, short[i] == long[i] { i += 1 }
        return Array(short[i...]) == Array(long[(i + 1)...])
    }

    // MARK: Word lists

    /// Word → index, for decoding a name back to its code in constant time.
    static let adjectiveIndex: [String: Int] = Dictionary(
        uniqueKeysWithValues: adjectives.enumerated().map { ($1, $0) })
    static let nounIndex: [String: Int] = Dictionary(
        uniqueKeysWithValues: nouns.enumerated().map { ($1, $0) })

    /// 256 adjectives, each ≥2 edits from every other in this list.
    /// `friendlyNameWordListsAreWellFormed` enforces that — do not add a word
    /// without running it.
    public static let adjectives: [String] = [
        "amber", "ancient", "arctic", "ardent", "ashen", "astral", "atomic", "azure",
        "blazing", "blissful", "bold", "brave", "bright", "brisk", "bronze", "calm",
        "careful", "carved", "casual", "celestial", "cerulean", "charmed", "chrome", "cinder",
        "civic", "clear", "clever", "coastal", "cobalt", "comic", "coral", "crafty",
        "crimson", "crystal", "curious", "dappled", "daring", "dawn", "deft", "dense",
        "desert", "devoted", "dire", "distant", "drifting", "dusky", "dynamic", "early",
        "eager", "ebony", "electric", "elegant", "emerald", "eternal", "evening", "exact",
        "fallen", "famous", "fearless", "fierce", "flame", "flint", "fluid", "forest",
        "frosted", "frozen", "furtive", "gallant", "gentle", "gilded", "glacial", "gleaming",
        "glowing", "golden", "grand", "granite", "green", "grim", "grounded", "hardy",
        "harmless", "hazy", "hidden", "hollow", "honest", "humble", "hushed", "idle",
        "indigo", "ivory", "jade", "jovial", "keen", "kindly", "knowing", "lavender",
        "lawful", "lean", "light", "lofty", "loyal", "lucky", "lunar", "majestic",
        "mellow", "midnight", "misty", "modest", "moonlit", "mossy", "muted", "mystic",
        "natural", "noble", "northern", "obscure", "olive", "opal", "orange", "pale",
        "pastel", "patient", "peaceful", "pearl", "pine", "polar", "primal", "quick",
        "quiet", "rapid", "remote", "restless", "rigid", "rising", "roaming", "robust",
        "rocky", "rosy", "rustic", "sacred", "sage", "sandy", "sapphire", "scarlet",
        "secret", "serene", "shadow", "sharp", "silent", "silver", "simple", "sincere",
        "slate", "sleek", "solid", "solitary", "somber", "southern", "spare", "spectral",
        "sprightly", "starlit", "steady", "steel", "stormy", "strange", "strong", "subtle",
        "summit", "sunny", "sunset", "swift", "teal", "tender", "thorny", "tidal",
        "timber", "tranquil", "twilight", "unique", "unlit", "unseen", "urban", "valiant",
        "vast", "velvet", "vivid", "volcanic", "wandering", "wary", "wild", "windy",
        "wise", "woven", "zesty", "alpine", "briny", "cloudy", "gloomy", "inky",
        "jolly", "knotty", "leafy", "murky", "narrow", "plum", "quirky", "rugged",
        "silky", "yonder", "zealous", "bleak", "crisp", "gaunt", "iron", "marbled",
        "nimble", "opaque", "quaint", "radiant", "rustling", "salty", "stoic", "tawny",
        "umbral", "verdant", "whimsical", "wintry", "youthful", "zephyrous", "bramble", "candid",
        "dappling", "earthen", "feathered", "glassy", "hearty", "ivied", "jaunty", "kindled",
        "mellowed", "nested", "oaken", "plush", "quilted", "ripened", "velveteen", "woolen",
        "amberish", "balmy", "citrine", "downy", "elder", "fernlike", "gossamer", "hallowed",
    ]

    /// 256 nouns, each ≥2 edits from every other in this list.
    public static let nouns: [String] = [
        "otter", "koala", "raven", "tiger", "walrus", "gecko", "heron", "beaver",
        "mantis", "badger", "falcon", "marmot", "ocelot", "puffin", "salmon", "weasel",
        "beetle", "cobra", "dingo", "ferret", "gopher", "hornet", "iguana", "jackal",
        "kitten", "lizard", "magpie", "shrimp", "osprey", "panda", "quail", "rabbit",
        "albatross", "alpaca", "antelope", "armadillo", "axolotl", "barracuda", "bison", "boar",
        "buffalo", "butterfly", "caiman", "camel", "capybara", "caracal", "caribou", "catfish",
        "chameleon", "cheetah", "chipmunk", "condor", "cormorant", "cougar", "coyote", "crane",
        "cricket", "crocodile", "dolphin", "donkey", "dragonfly", "dugong", "eagle", "echidna",
        "egret", "elephant", "finch", "firefly", "flamingo", "gorilla", "grizzly", "hamster",
        "hedgehog", "hippo", "hyena", "ibis", "impala", "jaguar", "kangaroo", "kestrel",
        "kiwi", "lemur", "leopard", "limpet", "lobster", "macaw", "manatee", "marlin",
        "meerkat", "mongoose", "moose", "narwhal", "newt", "numbat", "octopus", "okapi",
        "opossum", "orca", "ostrich", "oyster", "pangolin", "panther", "parrot", "peacock",
        "pelican", "penguin", "pheasant", "phoenix", "piranha", "platypus", "porcupine", "porpoise",
        "python", "quetzal", "raccoon", "reindeer", "rhino", "robin", "sandpiper", "scorpion",
        "skunk", "sloth", "snail", "sparrow", "spider", "squid", "squirrel", "starfish",
        "stingray", "stork", "swan", "tapir", "tarsier", "toad", "tortoise", "toucan",
        "trout", "turtle", "viper", "vulture", "wombat", "zebra", "canary", "cardinal",
        "clownfish", "nautilus", "lacewing", "lamprey", "linsang", "llama", "loris", "margay",
        "markhor", "mayfly", "moray", "oryx", "harrier", "hornbill", "ibex", "kinkajou",
        "glider", "genet", "hagfish", "opah", "anchor", "beacon", "bucket", "candle",
        "compass", "hammer", "kettle", "lantern", "mirror", "needle", "paddle", "pencil",
        "ribbon", "shovel", "whistle", "almond", "apricot", "basil", "cashew", "clove",
        "ginger", "honey", "lemon", "mango", "nutmeg", "papaya", "pepper", "pumpkin",
        "saffron", "vanilla", "walnut", "agate", "basalt", "copper", "diamond", "garnet",
        "marble", "pebble", "quartz", "topaz", "canyon", "delta", "fjord", "geyser",
        "glacier", "grotto", "island", "jungle", "lagoon", "meadow", "prairie", "ravine",
        "valley", "plateau", "anvil", "bellows", "chisel", "forge", "kiln", "loom",
        "mallet", "palette", "quill", "shears", "stencil", "thimble", "trowel", "abalone",
        "bobcat", "cuckoo", "dormouse", "eagleray", "finchling", "grouse", "hoopoe", "jerboa",
        "kudu", "lynx", "mallard", "nutria", "oriole", "plover", "quokka", "redstart",
        "serval", "tanager", "urchin", "vicuna", "wagtail", "yakut", "anemone", "barnacle",
    ]
}
