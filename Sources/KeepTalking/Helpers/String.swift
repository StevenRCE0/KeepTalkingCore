//
//  String.swift
//  KeepTalking
//
//  Created by 砚渤 on 13/10/2026.
//

import Foundation

extension String {
    public var beautifulName: String {
        self
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized(with: .autoupdatingCurrent)
    }
}
