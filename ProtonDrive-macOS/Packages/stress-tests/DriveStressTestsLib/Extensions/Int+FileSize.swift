//
//  Int+FileSize.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 18/01/2024.
//

import Foundation

/// sizeInBytes = 1.MB  // This will be 1,048,576 bytes (1 Megabyte)
extension Int {

    var kB: Int { self * 1_024 }
    var MB: Int { self * 1_024 * 1_024 }
    var GB: Int { self * 1_024 * 1_024 * 1_024 }
}
