//
//  SkillPlanner+Helpers.swift
//  KeepTalking
//
//  Supporting pieces for the planner: reading the skill directory (manifest and
//  file index), listing macOS Shortcuts, folding a turn into a transcript
//  message, and unwrapping `MCP.Value` tool arguments.
//

import AIProxy
import Foundation
import MCP

extension KeepTalkingSkillPlanner {

    // MARK: - Skill structure

    func loadManifest(for directory: URL, applying bundle: KeepTalkingSkillBundle) throws -> String {
        let url = SkillDirectoryDefinitions.entryURL(.manifest, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KeepTalkingSkillPlannerError.missingManifest(url)
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return String(bundle.applying(to: raw).prefix(Self.manifestMaxCharacters))
    }

    func buildFileIndex(for directory: URL) -> [String: [String]] {
        var index: [String: [String]] = [:]
        for entry: SkillDirectoryDefinitions.Entry in [.scripts, .references, .assets] {
            let entryURL = SkillDirectoryDefinitions.entryURL(entry, in: directory)
            index[entry.rawValue] = listRelativePaths(in: entryURL, root: directory)
        }
        return index
    }

    private func listRelativePaths(in directory: URL, root: URL) -> [String] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        let rootPath = root.standardizedFileURL.path
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                vals.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath + "/") { paths.append(String(path.dropFirst(rootPath.count + 1))) }
        }
        return paths.sorted()
    }

    // MARK: - Shortcuts listing

    func listMacOSShortcuts() async -> [String] {
        #if os(macOS)
        await MacOSShortcuts.list()
        #else
        []
        #endif
    }

    // MARK: - Message helper

    func assistantMessage(from turn: AITurnResult) -> AIMessage? {
        let text = turn.assistantText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = (text?.isEmpty == false)
        let toolCalls = turn.toolCalls.isEmpty ? nil : turn.toolCalls
        guard hasText || toolCalls != nil else { return nil }
        return AIMessage(
            role: .assistant,
            content: hasText ? .text(text!) : nil,
            toolCalls: toolCalls ?? []
        )
    }

    // MARK: - MCP.Value helpers

    func string(_ value: MCP.Value?) -> String? {
        guard case .string(let s) = value else { return nil }
        return s
    }

    func arrayOfStrings(_ value: MCP.Value) -> [String]? {
        guard case .array(let arr) = value else { return nil }
        return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }
}
