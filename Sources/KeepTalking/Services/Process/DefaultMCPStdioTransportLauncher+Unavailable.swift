#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
extension DefaultMCPStdioTransportLauncher {
    static var currentLauncher: (any MCPStdioTransportLaunching)? {
        nil
    }
}
#endif
