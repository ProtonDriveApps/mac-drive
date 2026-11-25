// Copyright (c) 2026 Proton AG
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

import Foundation

private final class PDLocalizationBundleToken {}

extension Bundle {
    static let module: Bundle = {
        let name = "PDLocalization_PDLocalization.bundle"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: PDLocalizationBundleToken.self).resourceURL,
            Bundle.main.bundleURL,
        ]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(name),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        fatalError("Missing PDLocalization resource bundle")
    }()
}
