import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// What a fetcher found at a link: the page's metadata and, when it names one,
/// the preview image ready to ship.
public struct KeepTalkingFetchedLinkPreview: Sendable {
    public struct Image: Sendable {
        public var data: Data
        public var mimeType: String
        public var width: Int?
        public var height: Int?

        public init(data: Data, mimeType: String, width: Int? = nil, height: Int? = nil) {
            self.data = data
            self.mimeType = mimeType
            self.width = width
            self.height = height
        }
    }

    public var metadata: KeepTalkingLinkMetadata
    public var image: Image?

    public init(metadata: KeepTalkingLinkMetadata, image: Image? = nil) {
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
    /// Pages read at most this much; the parser stops at `</head>` anyway.
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
        var headers: [AnyHashable: Any] = ["User-Agent": Self.userAgent]
        let languages = Locale.preferredLanguages.prefix(3)
        if !languages.isEmpty {
            headers["Accept-Language"] = languages.joined(separator: ",")
        }
        configuration.httpAdditionalHeaders = headers
        session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func preview(for url: URL) async -> KeepTalkingFetchedLinkPreview? {
        guard await LinkPreviewAddressPolicy.admits(url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
        guard
            let page = try? await read(
                request,
                limit: Self.pageByteLimit,
                stopsAtHeadEnd: true,
                accepts: { Self.isHTML($0.mimeType) }
            )
        else { return nil }
        let (body, response) = page

        let metadata = KeepTalkingLinkMetadata.parse(
            html: body,
            pageURL: response.url ?? url,
            contentType: response.value(forHTTPHeaderField: "Content-Type")
        )
        guard !metadata.isEmpty else { return nil }

        var image: KeepTalkingFetchedLinkPreview.Image?
        if let declared = metadata.image {
            image = await fetchImage(declared)
        }
        return KeepTalkingFetchedLinkPreview(metadata: metadata, image: image)
    }

    private func fetchImage(_ declared: KeepTalkingLinkMetadata.Image) async -> KeepTalkingFetchedLinkPreview.Image? {
        guard await LinkPreviewAddressPolicy.admits(declared.url) else { return nil }
        var request = URLRequest(url: declared.url)
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")
        guard
            let download = try? await read(
                request,
                limit: Self.imageDownloadByteLimit + 1,
                stopsAtHeadEnd: false,
                accepts: { Self.isRasterImage($0.mimeType) }
            ),
            download.0.count <= Self.imageDownloadByteLimit,
            let mimeType = download.1.mimeType
        else { return nil }
        let body = download.0

        let candidates = Self.imagePixelSizes.lazy.map {
            KeepTalkingImageDownscaler.downscaledIfNeeded(body, mimeType: mimeType, maxPixelSize: $0)
        }
        guard let scaled = candidates.first(where: { $0.data.count <= Self.shippedImageByteLimit }) else {
            return nil
        }
        // The declared size describes the original; it keeps the right aspect
        // ratio when the host can't measure the shipped bytes.
        let size = KeepTalkingImageDownscaler.pixelSize(of: scaled.data)
        return KeepTalkingFetchedLinkPreview.Image(
            data: scaled.data,
            mimeType: scaled.mimeType,
            width: size?.width ?? declared.width,
            height: size?.height ?? declared.height
        )
    }

    /// Reads a 2xx response body up to `limit` bytes, bailing out before the
    /// body when `accepts` rejects the response.
    private func read(
        _ request: URLRequest,
        limit: Int,
        stopsAtHeadEnd: Bool,
        accepts: (HTTPURLResponse) -> Bool
    ) async throws -> (Data, HTTPURLResponse) {
        #if canImport(FoundationNetworking)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), accepts(http)
        else { throw URLError(.badServerResponse) }
        return (data.prefix(limit), http)
        #else
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), accepts(http)
        else { throw URLError(.badServerResponse) }
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        var nextHeadCheck = 4096
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
            if stopsAtHeadEnd, data.count >= nextHeadCheck {
                if Self.containsHeadEnd(data, from: nextHeadCheck - 4096) { break }
                nextHeadCheck += 4096
            }
        }
        return (data, http)
        #endif
    }

    /// Whether `</head` or `<body` appears at or after `start` (the few bytes
    /// before it are rechecked so a split marker is still found).
    private static func containsHeadEnd(_ data: Data, from start: Int) -> Bool {
        let markers: [[UInt8]] = [Array("</head".utf8), Array("<body".utf8)]
        let lower = max(0, start - 6)
        let window = data[(data.startIndex + lower)...].map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }
        return markers.contains { marker in
            window.indices.contains { window[$0...].starts(with: marker) }
        }
    }

    private static func isHTML(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return false }
        return mimeType == "text/html" || mimeType == "application/xhtml+xml"
    }

    /// SVG is excluded: it can't be rasterised everywhere, and it can script.
    private static func isRasterImage(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return false }
        return mimeType.hasPrefix("image/") && !mimeType.contains("svg")
    }
}

/// Refuses a redirect that leads somewhere the fetcher wouldn't go directly.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, LinkPreviewAddressPolicy.allows(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Which hosts a link preview may be fetched from.
enum LinkPreviewAddressPolicy {
    private static let privateSuffixes = [
        ".localhost", ".local", ".internal", ".intranet", ".lan", ".home", ".corp", ".home.arpa",
    ]

    /// Http(s) only, to a host every resolved address of which is publicly
    /// routable. Resolving here and again when connecting leaves a window for
    /// DNS rebinding; the bar is keeping ordinary intranet names and literals
    /// out, not defeating a determined resolver.
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let rawHost = URLComponents(url: url, resolvingAgainstBaseURL: true)?.host
        else { return false }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard !host.isEmpty, host != "localhost", !privateSuffixes.contains(where: { host.hasSuffix($0) })
        else { return false }
        guard let addresses = resolvedAddresses(of: host), !addresses.isEmpty else { return false }
        return addresses.allSatisfy(isPubliclyRoutable)
    }

    /// `allows(_:)` for async callers, run on a queue of its own:
    /// `getaddrinfo` blocks for as long as the lookup takes and can't be
    /// cancelled, and a Swift concurrency thread pinned by a slow resolver
    /// stalls every task queued behind it.
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
    /// literal resolves to itself. Nil where the platform offers no resolver
    /// this can call, which refuses the fetch.
    static func resolvedAddresses(of host: String) -> [[UInt8]]? {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }

        var addresses: [[UInt8]] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = info.pointee.ai_addr else { continue }
            switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4 in
                        withUnsafeBytes(of: ipv4.pointee.sin_addr) { addresses.append(Array($0)) }
                    }
                case AF_INET6:
                    address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ipv6 in
                        withUnsafeBytes(of: ipv6.pointee.sin6_addr) { addresses.append(Array($0)) }
                    }
                default:
                    continue
            }
        }
        return addresses
        #else
        return nil
        #endif
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
