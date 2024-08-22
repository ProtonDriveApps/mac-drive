//
//  main.swift
//  DriveStressTests
//
//  Created by Rob on 15.01.2024.
//

import Foundation
import DriveStressTestsLib

let operationRandomizer = OperationRandomizer()

do {
    try await operationRandomizer.runTest()
    print("Test completed!")
} catch {
    print("Failed due to \(error)")
}
