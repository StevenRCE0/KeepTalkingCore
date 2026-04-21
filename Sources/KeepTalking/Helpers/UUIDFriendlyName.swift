import Foundation

extension UUID {
    /// A deterministic, human-friendly name derived from this UUID.
    ///
    /// The name is stable: the same UUID always produces the same string.
    /// Collision probability across the 65 536 possible combinations is low
    /// enough for any KeepTalking deployment (nodes, contexts, threads).
    ///
    /// Example outputs: "Happy Squid", "Crimson Falcon", "Glacial Panda"
    public var friendlyName: String {
        let b = uuid
        let adjIdx = (Int(b.0) << 8 | Int(b.1)) % UUIDFriendlyName.adjectives.count
        let nounIdx = (Int(b.2) << 8 | Int(b.3)) % UUIDFriendlyName.nouns.count
        return "\(UUIDFriendlyName.adjectives[adjIdx]) \(UUIDFriendlyName.nouns[nounIdx])"
    }
}

// MARK: - Word lists

enum UUIDFriendlyName {
    // 256 adjectives — vivid, unambiguous, easy to say aloud
    static let adjectives: [String] = [
        "Amber", "Ancient", "Arctic", "Ardent", "Ashen", "Astral", "Atomic", "Azure",
        "Blazing", "Blissful", "Blunt", "Bold", "Brave", "Bright", "Brisk", "Bronze",
        "Calm", "Careful", "Carved", "Casual", "Celestial", "Cerulean", "Charmed", "Chrome",
        "Cinder", "Civic", "Clear", "Clever", "Coastal", "Cobalt", "Comic", "Coral",
        "Cosmic", "Crafty", "Crimson", "Crystal", "Curious", "Cyan", "Dappled", "Daring",
        "Dark", "Dawn", "Deft", "Dense", "Desert", "Devoted", "Dire", "Distant",
        "Drifting", "Dusky", "Dynamic", "Early", "Eager", "Ebony", "Electric", "Elegant",
        "Emerald", "Eternal", "Evening", "Exact", "Fallen", "Famous", "Fearless", "Fierce",
        "Flame", "Flint", "Fluid", "Forest", "Frosted", "Frozen", "Furtive", "Gallant",
        "Gentle", "Ghost", "Gilded", "Glacial", "Gleaming", "Glowing", "Golden", "Grand",
        "Granite", "Grave", "Green", "Grey", "Grim", "Grounded", "Hardy", "Harmless",
        "Hazy", "Hidden", "Hollow", "Honest", "Humble", "Hushed", "Icy", "Idle",
        "Indigo", "Ivory", "Jade", "Jovial", "Keen", "Kind", "Knowing", "Lavender",
        "Lawful", "Lazy", "Lean", "Light", "Lime", "Lofty", "Lone", "Loyal",
        "Lucky", "Lunar", "Majestic", "Mellow", "Midnight", "Misty", "Modest", "Moonlit",
        "Mossy", "Muted", "Mystic", "Natural", "Noble", "North", "Oak", "Obscure",
        "Odd", "Olive", "Open", "Opal", "Orange", "Pale", "Pastel", "Patient",
        "Peaceful", "Pearl", "Pine", "Polar", "Primal", "Pure", "Quick", "Quiet",
        "Rapid", "Rare", "Raw", "Red", "Remote", "Restless", "Ridge", "Rigid",
        "Rising", "River", "Roaming", "Robust", "Rocky", "Rose", "Royal", "Rustic",
        "Sacred", "Sage", "Sandy", "Sapphire", "Scarlet", "Secret", "Serene", "Shadow",
        "Sharp", "Silent", "Silver", "Simple", "Sincere", "Slate", "Sleek", "Slow",
        "Solar", "Solid", "Solitary", "Somber", "South", "Spare", "Spectral", "Spry",
        "Starlit", "Steady", "Steel", "Stone", "Storm", "Strange", "Strong", "Subtle",
        "Summit", "Sunny", "Sunset", "Swift", "Teal", "Tender", "Thick", "Thin",
        "Thorny", "Tidal", "Timber", "Tiny", "Tranquil", "Twilight", "Unique", "Unlit",
        "Unseen", "Urban", "Valiant", "Vast", "Velvet", "Vivid", "Volcanic", "Wandering",
        "Wary", "Wild", "Windy", "Wise", "Woven", "Zesty", "Zenith", "Zinc",
        // padding to reach 256
        "Alpine", "Briny", "Cloudy", "Dusty", "Frosty", "Gloomy", "Hollow", "Inky",
        "Jolly", "Knotty", "Leafy", "Murky", "Narrow", "Onyx", "Plum", "Quirky",
        "Rugged", "Silky", "Thorough", "Umber", "Velvet", "Wavy", "Xenial", "Yonder",
        "Zealous", "Bleak", "Crisp", "Dull", "Faint", "Gaunt", "Hale", "Iron",
    ]

    // 256 nouns — memorable creatures and natural objects
    static let nouns: [String] = [
        "Albatross", "Alligator", "Alpaca", "Antelope", "Ape", "Armadillo", "Axolotl", "Badger",
        "Barracuda", "Bat", "Bear", "Beaver", "Bee", "Bison", "Boar", "Buffalo",
        "Butterfly", "Caiman", "Camel", "Capybara", "Caracal", "Caribou", "Cassowary", "Catfish",
        "Centipede", "Chameleon", "Cheetah", "Chinchilla", "Chipmunk", "Cobra", "Condor", "Coral",
        "Cormorant", "Cougar", "Coyote", "Crab", "Crane", "Cricket", "Crocodile", "Crow",
        "Dingo", "Dolphin", "Donkey", "Dragonfly", "Dugong", "Eagle", "Echidna", "Eel",
        "Egret", "Elephant", "Elk", "Emu", "Falcon", "Ferret", "Finch", "Firefly",
        "Flamingo", "Fox", "Frog", "Gecko", "Giraffe", "Gopher", "Gorilla", "Grasshopper",
        "Grizzly", "Hamster", "Hare", "Hawk", "Hedgehog", "Heron", "Hippo", "Hornet",
        "Hummingbird", "Hyena", "Ibis", "Iguana", "Impala", "Jackal", "Jaguar", "Jellyfish",
        "Kangaroo", "Kestrel", "Kingfisher", "Kiwi", "Koala", "Kookaburra", "Lemur", "Leopard",
        "Limpet", "Lion", "Lizard", "Lobster", "Loon", "Lynx", "Macaw", "Manatee",
        "Manta", "Marlin", "Meerkat", "Mink", "Mole", "Mongoose", "Monitor", "Moose",
        "Moth", "Narwhal", "Newt", "Nighthawk", "Numbat", "Ocelot", "Octopus", "Okapi",
        "Opossum", "Orca", "Osprey", "Ostrich", "Otter", "Owl", "Oyster", "Panda",
        "Pangolin", "Panther", "Parrot", "Peacock", "Pelican", "Penguin", "Peregrine", "Pheasant",
        "Phoenix", "Piranha", "Platypus", "Porcupine", "Porpoise", "Prairie Dog", "Python", "Quail",
        "Quetzal", "Rabbit", "Raccoon", "Raven", "Ray", "Reindeer", "Rhino", "Robin",
        "Salamander", "Salmon", "Sandpiper", "Scorpion", "Sea Horse", "Seal", "Shark", "Skunk",
        "Sloth", "Snail", "Snow Leopard", "Sparrow", "Spider", "Squid", "Squirrel", "Starfish",
        "Stingray", "Stork", "Swan", "Swift", "Tapir", "Tarsier", "Tiger", "Toad",
        "Tortoise", "Toucan", "Trout", "Tuna", "Turtle", "Viper", "Vulture", "Walrus",
        "Wasp", "Weasel", "Whale", "Wildcat", "Wolf", "Wolverine", "Wombat", "Woodpecker",
        "Wren", "Yak", "Zebra", "Zebrafish", "Zorilla", "Albatross", "Bald Eagle", "Blue Jay",
        "Boa", "Buffalo", "Bull", "Canary", "Cardinal", "Clownfish", "Cuttlefish", "Darter",
        "Dove", "Draco", "Dragonet", "Dung Beetle", "Firebird", "Flying Fox", "Flying Squirrel", "Frilled Lizard",
        "Genet", "Ghost Bat", "Giant Squid", "Glider", "Golden Mole", "Ground Squirrel", "Hagfish", "Harrier",
        "Honeybee", "Hornbill", "Ibex", "Imperial Eagle", "Iriomote Cat", "Jewel Beetle", "Kinkajou", "Kit Fox",
        "Klipspringer", "Lacewing", "Lamprey", "Lanternfish", "Leafbird", "Linsang", "Llama", "Loris",
        "Lugworm", "Mantis", "Margay", "Markhor", "Marsh Harrier", "Mayfly", "Mole Rat", "Moon Bear",
        "Moray", "Musk Deer", "Nautilus", "Needlefish", "Night Heron", "Numbfish", "Opah", "Oryx",
    ]
}
