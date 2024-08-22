//
//  DataGenerator.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 18/01/2024.
//

import Foundation
import os

extension Logger {

    private static let subsystem = "ch.protonmail.drive.DriveStressTests"

    private static let performanceCategory = "Performance"

    static let performance = Logger(subsystem: subsystem, category: performanceCategory)
}
