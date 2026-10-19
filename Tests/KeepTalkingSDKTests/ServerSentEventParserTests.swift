#if canImport(FoundationNetworking)
import Foundation
import Testing

@testable import KeepTalkingSDK

/// The event-stream reader behind the Linux MCP transport: an event is its
/// `data` lines joined, and nothing else in the stream reaches the client.
@Suite("ServerSentEventParser")
struct ServerSentEventParserTests {
    @Test("An event arrives whole however the bytes are split")
    func splitAcrossChunks() {
        var parser = ServerSentEventParser()
        #expect(parser.feed(Data("event: message\ndata: {\"id\"".utf8)).isEmpty)
        #expect(parser.feed(Data(":1}\n".utf8)).isEmpty)
        #expect(parser.feed(Data("\n".utf8)) == ["{\"id\":1}"])
    }

    @Test("CRLF lines, multi-line data, comments and other fields")
    func fields() {
        var parser = ServerSentEventParser()
        let events = parser.feed(Data(": keep-alive\r\n\r\nid: 7\r\nretry: 100\r\ndata: a\r\ndata:b\r\n\r\n".utf8))
        #expect(events == ["a\nb"])
    }

    @Test("A keep-alive comment alone is not an event")
    func keepAlive() {
        var parser = ServerSentEventParser()
        #expect(parser.feed(Data(": keep-alive\n\n".utf8)).isEmpty)
        #expect(parser.finish().isEmpty)
    }

    @Test("A stream that ends without its blank line still yields the event")
    func unterminated() {
        var parser = ServerSentEventParser()
        #expect(parser.feed(Data("data: {\"id\":2}".utf8)).isEmpty)
        #expect(parser.finish() == ["{\"id\":2}"])
    }
}
#endif
