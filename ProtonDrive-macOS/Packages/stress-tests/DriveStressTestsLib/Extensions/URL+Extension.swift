//
//  URL+Extension.swift
//  DriveStressTests
//
//  Created by Rob on 18.01.2024.
//

import Foundation

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
