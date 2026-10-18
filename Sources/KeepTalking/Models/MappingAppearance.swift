import Foundation

/// How a mapping looks: a colour, an icon and an avatar, each optional.
///
/// Stored as one JSON value on the mapping row, so a new property or glyph
/// kind is a new optional key, never a schema change. Colour and icon are
/// lists of ``Variant``s — the first one that applies to the rendering
/// platform wins — so a value can carry a per-platform override (an SF Symbol
/// on Apple, an emoji elsewhere). The avatar is one image for every platform,
/// held in the blob store by content hash.
///
/// No property is restricted by target or kind; the host's UI decides which
/// ones it offers where.
public struct KeepTalkingMappingAppearance: Codable, Hashable, Sendable {
    public var color: [Variant<String>]
    public var icon: [Variant<Glyph>]
    public var avatar: Avatar?

    public init(
        color: [Variant<String>] = [],
        icon: [Variant<Glyph>] = [],
        avatar: Avatar? = nil
    ) {
        self.color = color
        self.icon = icon
        self.avatar = avatar
    }

    /// True when nothing is set — such an appearance is stored as no
    /// appearance at all.
    public var isEmpty: Bool {
        color.isEmpty && icon.isEmpty && avatar == nil
    }

    /// The first colour (a `#RRGGBB` hex) that applies to `platform`.
    public func color(for platform: KeepTalkingPlatform) -> String? {
        color.first { $0.applies(to: platform) }?.value
    }

    /// Every icon that may render on `platform`, best first. A renderer takes
    /// the first it can actually draw — an SF Symbol newer than the running
    /// OS, say, falls through to the next.
    public func icons(for platform: KeepTalkingPlatform) -> [Glyph] {
        icon.filter { $0.applies(to: platform) && $0.value.renders(on: platform) }
            .map(\.value)
    }

    /// Per-property fallback: each property this appearance leaves unset is
    /// taken from `base`. A context-scoped alias that only sets a colour keeps
    /// the global alias's avatar.
    public func overlaying(_ base: Self?) -> Self {
        guard let base else { return self }
        return Self(
            color: color.isEmpty ? base.color : color,
            icon: icon.isEmpty ? base.icon : icon,
            avatar: avatar ?? base.avatar
        )
    }

    /// Trimmed, with empty entries dropped — the form it's stored in.
    func normalized() -> Self {
        Self(
            color: color.compactMap { variant in
                KeepTalkingMapping.normalizeOptional(variant.value).map {
                    variant.with(value: $0)
                }
            },
            icon: icon.compactMap { variant in
                variant.value.normalized().map { variant.with(value: $0) }
            },
            avatar: avatar
        )
    }

    /// Blobs this appearance keeps alive.
    var blobIDs: Set<String> {
        avatar.map { [$0.blobID] } ?? []
    }
}

extension KeepTalkingMappingAppearance {
    /// One value, optionally restricted to some platforms.
    public struct Variant<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
        public let value: Value
        /// Nil applies everywhere. Kept sorted and unique, so equal variants
        /// encode identically.
        public let platforms: Set<KeepTalkingPlatform>?

        /// An empty set would apply nowhere; it means "everywhere" instead.
        public init(_ value: Value, platforms: Set<KeepTalkingPlatform>? = nil) {
            self.value = value
            self.platforms = platforms.flatMap { $0.isEmpty ? nil : $0 }
        }

        public func applies(to platform: KeepTalkingPlatform) -> Bool {
            platforms?.contains(platform) ?? true
        }

        func with<Other>(value: Other) -> Variant<Other> {
            Variant<Other>(value, platforms: platforms.map(Set.init))
        }

        private enum CodingKeys: String, CodingKey {
            case value
            case platforms
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(Value.self, forKey: .value)
            platforms = try container.decodeIfPresent(Set<KeepTalkingPlatform>.self, forKey: .platforms)
        }

        /// A set encodes in hash order, which two equal sets needn't share, so
        /// the platforms go out sorted.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(platforms?.sorted { $0.rawValue < $1.rawValue }, forKey: .platforms)
        }
    }

    public enum Glyph: Codable, Hashable, Sendable {
        /// An SF Symbol name. Renders on Apple platforms only, tagged or not.
        case sfSymbol(name: String)
        case emoji(value: String)

        public func renders(on platform: KeepTalkingPlatform) -> Bool {
            switch self {
                case .sfSymbol: platform == .apple
                case .emoji: true
            }
        }

        func normalized() -> Self? {
            switch self {
                case .sfSymbol(let name):
                    KeepTalkingMapping.normalizeOptional(name).map { .sfSymbol(name: $0) }
                case .emoji(let value):
                    KeepTalkingMapping.normalizeOptional(value).map { .emoji(value: $0) }
            }
        }
    }

    /// An image in the blob store, by content hash. A blob that isn't there
    /// (yet, or any more) reads as no avatar.
    public struct Avatar: Codable, Hashable, Sendable {
        public var blobID: String
        public var shape: Shape

        public init(blobID: String, shape: Shape = .circle) {
            self.blobID = blobID
            self.shape = shape
        }

        public enum Shape: String, Codable, Hashable, Sendable {
            case circle
            case roundedSquare
        }
    }
}
