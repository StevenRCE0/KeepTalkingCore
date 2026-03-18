public enum DefaultMCPStdioTransportLauncher {
    public static var current: (any MCPStdioTransportLaunching)? {
        currentLauncher
    }
}
