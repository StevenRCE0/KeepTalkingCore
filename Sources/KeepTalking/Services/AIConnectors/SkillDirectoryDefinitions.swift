//
//  SkillDirectoryDefinitions.swift
//  KeepTalking
//
//  Created by 砚渤 on 28/02/2026.
//

import Foundation

enum SkillDirectoryDefinitions {
    enum Entry: String, CaseIterable, Sendable {
        case manifest = "SKILL.md"
        case references = "references"
        case scripts = "scripts"
        case assets = "assets"

        var isDirectory: Bool {
            switch self {
                case .manifest:
                    return false
                case .references, .scripts, .assets:
                    return true
            }
        }
    }

    static let requiredEntries: Set<Entry> = [.manifest]
    static let optionalEntries: Set<Entry> = [.references, .scripts, .assets]

    static func entryURL(_ entry: Entry, in skillDirectory: URL) -> URL {
        skillDirectory.appendingPathComponent(
            entry.rawValue,
            isDirectory: entry.isDirectory
        )
    }

    static var defaultSkillRootDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }
}
