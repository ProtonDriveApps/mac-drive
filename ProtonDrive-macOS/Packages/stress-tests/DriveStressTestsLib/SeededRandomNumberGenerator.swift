//
//  SeededRandomNumberGenerator.swift
//  DriveStressTests
//
//  Created by Rob on 15.01.2024.
//

import Foundation
import GameplayKit

struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private let generatorAlgorithm: GKMersenneTwisterRandomSource
    
    init(seed: UInt64) {
        generatorAlgorithm = GKMersenneTwisterRandomSource(seed: seed)
    }
    
    mutating func next() -> UInt64 {
        let firstHalf = UInt64(bitPattern: Int64(generatorAlgorithm.nextInt()))
        let secondHalf = UInt64(bitPattern: Int64(generatorAlgorithm.nextInt()))
        return firstHalf ^ (secondHalf << 32)
    }
}
