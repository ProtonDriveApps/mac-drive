// Copyright (c) 2023 Proton AG
//
// This file is part of Proton Drive.
//
// Proton Drive is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Proton Drive is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Proton Drive. If not, see https://www.gnu.org/licenses/.

import PDCore
import ProtonCoreUIFoundations

protocol ReleaseNotesViewModelProtocol {
    var releaseNotes: String { get }
}

final class ReleaseNotesViewModel: ReleaseNotesViewModelProtocol {
    
    private let bundle: Bundle
    
    var releaseNotes: String {
        // the envelope provides padding and styling and dark mode support
        let backgroundColor: NSColor = ColorProvider.BackgroundNorm
        let foregroundColor: NSColor = ColorProvider.TextNorm
        let paddingInPx: Int = 24
        return """
               <!DOCTYPE html>
               <html>
               <head>
               <style>
               :root {
                 color-scheme: light dark;
               }
               body {
                 background-color: \(backgroundColor.cssValue);
                 color: \(foregroundColor.cssValue);
               }
               </style>
               </head>
               <body style="padding: \(paddingInPx)px">
               \(releaseNotesContent)
               </body>
               </html>
               """
    }
    
    private var releaseNotesContent: String {
        guard let releaseNotesFilePath = bundle.path(forResource: "ReleaseNotes", ofType: "html") else {
            Log.error("ReleaseNotes.html file missing", domain: .application)
            assertionFailure("ReleaseNotes.html file missing")
            return ""
        }
        do {
            return try String(contentsOfFile: releaseNotesFilePath)
        } catch {
            Log.error("ReleaseNotes.html file reading failed with error \(error.localizedDescription)", domain: .application)
            assertionFailure("ReleaseNotes.html file reading failed with error \(error)")
            return ""
        }
    }
    
    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }
}

private extension NSColor {
    var cssValue: String {
        String(format: "#%02x%02x%02x%02x",
               Int(redComponent * 255),
               Int(greenComponent * 255),
               Int(blueComponent * 255),
               Int(alphaComponent * 255))
    }
}
