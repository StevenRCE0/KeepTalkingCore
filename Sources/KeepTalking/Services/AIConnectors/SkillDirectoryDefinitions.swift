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

    static func entryURL(_ entry: Entry, in skillDirectory: URL) -> URL {
        skillDirectory.appendingPathComponent(
            entry.rawValue,
            isDirectory: entry.isDirectory
        )
    }
}
