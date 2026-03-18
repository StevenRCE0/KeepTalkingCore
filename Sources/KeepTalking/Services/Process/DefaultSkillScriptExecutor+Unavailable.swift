#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
extension DefaultSkillScriptExecutor {
    static var currentExecutor: (any SkillScriptExecuting)? {
        nil
    }
}
#endif
