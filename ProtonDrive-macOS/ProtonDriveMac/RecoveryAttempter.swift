// Copyright (c) 2024 Proton AG
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

final class RecoveryAttempter: NSObject {
    private var options = [(title: String, block: (Error) -> Bool)]()
    
    func option(with title: String, block: @escaping (Error) -> Bool) {
        options.append((title, block))
    }
    
    var localizedRecoveryOptions: [String] {
        return options.map(\.title)
    }
    
    override func attemptRecovery(fromError error: Error, optionIndex recoveryOptionIndex: Int) -> Bool {
        let option = options[recoveryOptionIndex]
        return option.block(error)
    }
}
