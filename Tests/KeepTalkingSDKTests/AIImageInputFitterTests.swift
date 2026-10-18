import Foundation
import Testing

@testable import KeepTalkingSDK

/// No downscaler is registered in the SDK tests, so the fitter sees images as
/// they are: these cover the budget arithmetic, not re-encoding.
struct AIImageInputFitterTests {
    private static func imagePart(bytes: Int, mimeType: String = "image/png") -> AIMessage.Part {
        let base64 = Data(repeating: 0xAB, count: bytes).base64EncodedString()
        return .imageURL(URL(string: "data:\(mimeType);base64,\(base64)")!)
    }

    private static func policy(
        perImage: Int, perRequest: Int, images: Int = 10
    ) -> AIImageInputPolicy {
        AIImageInputPolicy(
            maxPixelSize: 1568,
            maxEncodedBytesPerImage: perImage,
            maxEncodedBytesPerRequest: perRequest,
            maxImagesPerRequest: images,
            headroom: 0
        )
    }

    private static func imageCount(_ messages: [AIMessage]) -> Int {
        messages.reduce(0) { total, message in
            guard case .parts(let parts) = message.content else { return total }
            return total + parts.filter { if case .imageURL = $0 { true } else { false } }.count
        }
    }

    private static func texts(_ message: AIMessage) -> [String] {
        guard case .parts(let parts) = message.content else { return [] }
        return parts.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    @Test("an image over the per-image budget becomes a note")
    func dropsOversizedImage() {
        let messages: [AIMessage] = [.user(parts: [.text("look"), Self.imagePart(bytes: 3_000)])]
        let fitted = AIImageInputFitter().fitted(
            messages, policy: Self.policy(perImage: 2_000, perRequest: 100_000))

        #expect(Self.imageCount(fitted) == 0)
        #expect(Self.texts(fitted[0]) == ["look", AIImageInputFitter.oversizedImageNote])
    }

    @Test("the request budget keeps the newest images and drops older ones")
    func spendsRequestBudgetNewestFirst() {
        let messages: [AIMessage] = [
            .user(parts: [Self.imagePart(bytes: 1_000)]),
            .assistant("seen"),
            .user(parts: [Self.imagePart(bytes: 1_000)]),
        ]
        let fitted = AIImageInputFitter().fitted(
            messages, policy: Self.policy(perImage: 2_000, perRequest: 2_000))

        #expect(Self.texts(fitted[0]) == [AIImageInputFitter.overBudgetImageNote])
        #expect(Self.imageCount([fitted[2]]) == 1)
    }

    @Test("the image count limit applies across the request")
    func capsImageCount() {
        let messages: [AIMessage] = [
            .user(parts: [Self.imagePart(bytes: 10), Self.imagePart(bytes: 10), Self.imagePart(bytes: 10)])
        ]
        let fitted = AIImageInputFitter().fitted(
            messages, policy: Self.policy(perImage: 2_000, perRequest: 100_000, images: 2))

        #expect(Self.imageCount(fitted) == 2)
        #expect(Self.texts(fitted[0]) == [AIImageInputFitter.overBudgetImageNote])
    }

    @Test("a type the endpoint doesn't decode is dropped when nothing can transcode it")
    func dropsUnacceptedTypeWithoutDownscaler() {
        let messages: [AIMessage] = [.user(parts: [Self.imagePart(bytes: 10, mimeType: "image/heic")])]
        let fitted = AIImageInputFitter().fitted(
            messages, policy: Self.policy(perImage: 2_000, perRequest: 100_000))

        #expect(Self.imageCount(fitted) == 0)
    }

    @Test("remote image URLs pass through and cost nothing")
    func passesRemoteURLs() {
        let remote = URL(string: "https://example.com/cat.png")!
        let messages: [AIMessage] = [.user(parts: [.imageURL(remote)])]
        let fitted = AIImageInputFitter().fitted(
            messages, policy: Self.policy(perImage: 1, perRequest: 1))

        #expect(fitted == messages)
    }

    @Test("byte budgets count base64 and hold back headroom")
    func budgetsCountBase64() {
        let policy = AIImageInputPolicy.anthropic
        #expect(policy.targetEncodedBytesPerImage == Int(Double(5 * 1024 * 1024) * 0.85))
        let binary = policy.encodingTarget.maxBytes!
        #expect((binary + 2) / 3 * 4 + 64 <= policy.targetEncodedBytesPerImage)
    }

    @Test("a routed model takes its vendor's limits")
    func routesByVendorPrefix() {
        #expect(AIImageInputPolicy.routed(model: "anthropic/claude-opus-4") == .anthropic)
        #expect(AIImageInputPolicy.routed(model: "openai/gpt-5") == .openAI)
        #expect(AIImageInputPolicy.routed(model: "google/gemini-3-pro") == .conservative)
    }
}
