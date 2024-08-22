//
//  Constants.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 18/01/2024.
//

import Foundation

@MainActor
enum Constants {

    // Seeded random number generator
    private static var randomSeedGenerator = SystemRandomNumberGenerator()
    private static let seed = UInt64.random(in: 0..<1_000_000_000, using: &randomSeedGenerator)
    // Or use a previously-generated seed to reproduce sequence from previous run(s)
//    private static let seed = x
    static var seededRNG = SeededRandomNumberGenerator(seed: seed)

    static func randomDelay(in range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &seededRNG)
    }
}
