// The macOS impl (+Process) uses SeatbeltSandbox/SkillScriptRunner and is
// #if os(macOS); this "unavailable" stub must therefore cover every non-macOS
// platform (iOS family AND Linux/Windows), not just the Apple ones.
#if !os(macOS)
extension DefaultSkillScriptExecutor {
    static var currentExecutor: (any SkillScriptExecuting)? {
        nil
    }
}
#endif
