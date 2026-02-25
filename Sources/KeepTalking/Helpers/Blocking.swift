//
//  Blocking.swift
//  KeepTalking
//
//  Created by 砚渤 on 25/02/2026.
//

import Foundation
import NIOConcurrencyHelpers

func blocking<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = NIOLockedValueBox<Result<T, Error>?>(nil)

    Task {
        do {
            let result = try await operation()
            resultBox.withLockedValue { $0 = .success(result) }
        } catch {
            resultBox.withLockedValue { $0 = .failure(error) }
        }
        semaphore.signal()
    }

    semaphore.wait()
    guard let result = resultBox.withLockedValue({ $0 }) else {
        fatalError(
            "KeepTalkingModelStore blocking task did not produce a result."
        )
    }
    return try result.get()
}
