import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a fetcher found at a link: the page's metadata and, when it names one,
/// the preview image ready to ship.
public struct KeepTalkingFetchedLinkPreview: Sendable {
    public var metadata: KeepTalkingLinkMetadata
    public var image: KeepTalkingLinkPreview.Image?

    public init(metadata: KeepTalkingLinkMetadata, image: KeepTalkingLinkPreview.Image? = nil) {
        self.metadata = metadata
        self.image = image
    }
}

/// Fetches link previews for the send path. Installed on a client with
/// `KeepTalkingClient.setLinkPreviewFetcher(_:)`; a client without one sends
/// messages with no previews.
public protocol KeepTalkingLinkPreviewFetching: Sendable {
    /// The preview for `url`, or nil when there is nothing to show. Must honour
    /// task cancellation: the send path stops waiting after a short budget.
    func preview(for url: URL) async -> KeepTalkingFetchedLinkPreview?
}

/// The network-backed fetcher: reads the top of the page, parses it with
/// `KeepTalkingLinkMetadata`, then fetches and downscales the preview image.
///
/// Links in messages come from people and from agents, so an agent that was
/// talked into writing an intranet URL must not make this node fetch it and
/// ship the result to peers. Every request — including each redirect hop — is
/// refused unless all of its host's addresses are publicly routable. Requests
/// carry no cookies and nothing is cached.
public final class KeepTalkingLinkPreviewFetcher: KeepTalkingLinkPreviewFetching {
    /// Pages read at most this much; reading also stops at the end of `<head>`.
    static let pageByteLimit = KeepTalkingLinkMetadata.headByteLimit
    /// Images larger than this are skipped rather than downloaded.
    static let imageDownloadByteLimit = 5 * 1024 * 1024
    /// Longest sides tried for the shipped image, best first: 960 px is a
    /// ~320 pt card at 3x. The image travels inline in the message, so when a
    /// size lands over `shippedImageByteLimit` (a detailed PNG stays PNG) the
    /// next one down is tried before the card goes text-only.
    static let imagePixelSizes = [960, 720, 480]
    static let shippedImageByteLimit = 256 * 1024

    /// Sites that only put Open Graph tags in front of known crawlers look for
    /// these tokens, so the agent names itself and them.
    static let userAgent =
        "Mozilla/5.0 (compatible; KeepTalking/1.0; +https://docs.keeptalking.dev) "
        + "facebookexternalhit/1.1 Twitterbot/1.0"

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        configuration.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Accept-Language": Locale.preferredLanguages.prefix(3).joined(separator: ","),
        ]
        session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func preview(for url: URL) async -> KeepTalkingFetchedLinkPreview? {
        guard
            let page = await read(
                url,
                accepting: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
                limit: Self.pageByteLimit,
                stopsAtHeadEnd: true,
                typeMatches: { $0 == "text/html" || $0 == "application/xhtml+xml" }
            )
        else { return nil }
        let metadata = KeepTalkingLinkMetadata.parse(
            html: page.body,
            pageURL: page.response.url ?? url,
            contentType: page.response.value(forHTTPHeaderField: "Content-Type")
        )
        guard !metadata.isEmpty else { return nil }
        return KeepTalkingFetchedLinkPreview(metadata: metadata, image: await image(metadata.image))
    }

    /// The declared image, downscaled until it fits inline in a message.
    private func image(_ declared: KeepTalkingLinkMetadata.Image?) async -> KeepTalkingLinkPreview.Image? {
        guard let declared,
            // One byte over the limit tells a large image from one that fits.
            let download = await read(
                declared.url,
                accepting: "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8",
                limit: Self.imageDownloadByteLimit + 1,
                // SVG can't be rasterised everywhere, and it can script.
                typeMatches: { $0.hasPrefix("image/") && !$0.contains("svg") }
            ),
            download.body.count <= Self.imageDownloadByteLimit,
            let mimeType = download.response.mimeType,
            let scaled = Self.imagePixelSizes.lazy
                .map({
                    KeepTalkingImageDownscaler.downscaledIfNeeded(download.body, mimeType: mimeType, maxPixelSize: $0)
                })
                .first(where: { $0.data.count <= Self.shippedImageByteLimit })
        else { return nil }
        // The declared size describes the original; it keeps the right aspect
        // ratio when the host can't measure the shipped bytes.
        let size = KeepTalkingImageDownscaler.pixelSize(of: scaled.data)
        return KeepTalkingLinkPreview.Image(
            data: scaled.data,
            mimeType: scaled.mimeType,
            width: size?.width ?? declared.width,
            height: size?.height ?? declared.height,
            alt: declared.alt
        )
    }

    /// Up to `limit` bytes of a 2xx response whose MIME type matches, or nil
    /// — for a refused host, an error, or any other response.
    private func read(
        _ url: URL,
        accepting accept: String,
        limit: Int,
        stopsAtHeadEnd: Bool = false,
        typeMatches: (String) -> Bool
    ) async -> (body: Data, response: HTTPURLResponse)? {
        guard await LinkPreviewAddressPolicy.admits(url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let mimeType = http.mimeType?.lowercased(), typeMatches(mimeType)
        else { return nil }

        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= limit { break }
                if stopsAtHeadEnd, byte == UInt8(ascii: ">"), Self.closesHead(body) { break }
            }
        } catch {
            return nil
        }
        return (body, http)
    }

    /// Whether the tag that ends `body` is `</head …>` or `<body …>`: what
    /// the metadata needs has all arrived.
    private static func closesHead(_ body: Data) -> Bool {
        guard let open = body.lastIndex(of: UInt8(ascii: "<")) else { return false }
        let tag = String(decoding: body[open...].prefix(6), as: UTF8.self).lowercased()
        return tag.hasPrefix("</head") || tag.hasPrefix("<body")
    }
}

/// Refuses a redirect that leads somewhere the fetcher wouldn't go directly.
/// URLSession calls it on its own delegate queue, where blocking on a host
/// lookup is no harm.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allowed = request.url.map(LinkPreviewAddressPolicy.allows) ?? false
        completionHandler(allowed ? request : nil)
    }
}

/// Which hosts a link preview may be fetched from: http(s) only, to a host
/// every resolved address of which is publicly routable. Resolving here and
/// again when connecting leaves a window for DNS rebinding; the bar is keeping
/// ordinary intranet names and literals out, not defeating a determined
/// resolver.
enum LinkPreviewAddressPolicy {
    private static let privateSuffixes = [
        ".localhost", ".local", ".internal", ".intranet", ".lan", ".home", ".corp", ".home.arpa",
    ]

    /// Blocks for the host lookup; async code calls `admits(_:)` instead.
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = URLComponents(url: url, resolvingAgainstBaseURL: true)?.host?
                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[].")),
            !host.isEmpty, host != "localhost", !privateSuffixes.contains(where: { host.hasSuffix($0) })
        else { return false }
        let addresses = resolvedAddresses(of: host)
        return !addresses.isEmpty && addresses.allSatisfy(isPubliclyRoutable)
    }

    /// `allows(_:)` on a queue of its own: `getaddrinfo` blocks for as long as
    /// the lookup takes and can't be cancelled, and a Swift concurrency thread
    /// pinned by a slow resolver stalls every task queued behind it.
    static func admits(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            resolverQueue.async { continuation.resume(returning: allows(url)) }
        }
    }

    private static let resolverQueue = DispatchQueue(
        label: "KeepTalking.LinkPreview.resolver",
        qos: .utility,
        attributes: .concurrent
    )

    /// Every IPv4 (4-byte) and IPv6 (16-byte) address `host` resolves to — a
    /// literal resolves to itself. Empty when it doesn't resolve.
    static func resolvedAddresses(of host: String) -> [[UInt8]] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        return sequence(first: first, next: { $0.pointee.ai_next }).compactMap { info in
            guard let address = info.pointee.ai_addr else { return nil }
            switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
                    }
                case AF_INET6:
                    return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                    }
                default:
                    return nil
            }
        }
    }

    static func isPubliclyRoutable(_ address: [UInt8]) -> Bool {
        switch address.count {
            case 4:
                let (a, b, c) = (address[0], address[1], address[2])
                switch a {
                    case 0, 10, 127: return false
                    case 100 where b & 0xC0 == 64: return false  // 100.64/10 carrier-grade NAT
                    case 169 where b == 254: return false  // link-local
                    case 172 where b & 0xF0 == 16: return false
                    case 192 where b == 168: return false
                    case 192 where b == 0 && c == 0: return false
                    case 198 where b & 0xFE == 18: return false  // 198.18/15 benchmarking
                    case 224...: return false  // multicast and reserved
                    default: return true
                }
            case 16:
                if address.allSatisfy({ $0 == 0 }) { return false }  // ::
                if address.prefix(15).allSatisfy({ $0 == 0 }) && address[15] == 1 { return false }  // ::1
                if address[0] & 0xFE == 0xFC { return false }  // fc00::/7 unique local
                if address[0] == 0xFE && address[1] & 0xC0 == 0x80 { return false }  // fe80::/10
                if address[0] == 0xFF { return false }  // multicast
                // IPv4-mapped (::ffff:a.b.c.d) and NAT64 (64:ff9b::a.b.c.d) carry an
                // IPv4 address that decides for them.
                let isMapped = address.prefix(10).allSatisfy { $0 == 0 } && address[10] == 0xFF && address[11] == 0xFF
                let isNAT64 = address.prefix(12).elementsEqual([0, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0])
                if isMapped || isNAT64 { return isPubliclyRoutable(Array(address.suffix(4))) }
                return true
            default:
                return false
        }
    }
}
