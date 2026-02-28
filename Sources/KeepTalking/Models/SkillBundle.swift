//
//  SkillBundle.swift
//  KeepTalking
//
//  Created by 砚渤 on 28/02/2026.
//

import Foundation

public struct KeepTalkingSkillBundle: KeepTalkingActionBundle {
    public var id: UUID
    public var name: String
    public var indexDescription: String
    public var directory: URL

    public init(
        id: UUID = UUID(),
        name: String,
        indexDescription: String,
        directory: URL
    ) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
        self.directory = directory
    }
}
