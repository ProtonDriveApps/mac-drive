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

public protocol FileUploadConfiguration {
    func isEncryptionParallel() -> Bool
}

final class ParallelEncryptionUploadConfiguration: FileUploadConfiguration {
    @SettingsStorage("parallelEncryptionAndVerificationQA") var parallelEncryptionAndVerification: Bool?

    private let featureFlagsRepository: FeatureFlagsRepository

    init(featureFlagsRepository: FeatureFlagsRepository) {
        self.featureFlagsRepository = featureFlagsRepository
        if Constants.buildType.isQaOrBelow {
            _parallelEncryptionAndVerification.configure(with: .group(named: Constants.appGroup))
        }
    }

    func isEncryptionParallel() -> Bool {
        if Constants.buildType.isQaOrBelow {
            return parallelEncryptionAndVerification ?? featureFlagsRepository.isEnabled(flag: .parallelEncryptionAndVerification)
        } else {
            return featureFlagsRepository.isEnabled(flag: .parallelEncryptionAndVerification)
        }
    }
}

final class SerialEncryptionFileUploadConfiguration: FileUploadConfiguration {
    func isEncryptionParallel() -> Bool {
        return false
    }
}
