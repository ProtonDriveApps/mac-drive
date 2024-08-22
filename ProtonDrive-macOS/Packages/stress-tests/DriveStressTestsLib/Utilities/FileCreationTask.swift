//
//  FileCreationTask.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 19/01/2024.
//

import Foundation
import os

struct FileCreationTask<T> {
    var createTask: () async throws -> T

    func withPerformanceLogging(taskName: String) -> () async throws -> T {
        return {
            let start = Date()
            let result = try await self.createTask()
            let end = Date()
            let duration = end.timeIntervalSince(start)
            Logger.performance.info("\(taskName) completed in \(duration) seconds.")
            return result
        }
    }
}
