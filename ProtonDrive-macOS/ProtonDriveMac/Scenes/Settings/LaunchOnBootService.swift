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

import Combine
import PDCore
import ServiceManagement

protocol LaunchOnBootServiceProtocol: AnyObject {
    var isLaunchOnBootEnabled: Bool { get set }
    var isLaunchOnBootEnabledPublisher: AnyPublisher<Bool, Never> { get }
    var launchOnBootUserFacingMessage: String? { get }
    var launchOnBootUserFacingMessagePublisher: AnyPublisher<String?, Never> { get }
    func userSignedIn()
    func userSignedOut()
}

// This service uses the legacy api for launch on boot. The new API, available from macOS 13,
// based on SMAppService class, was working unreliably during tests. It was not launching the app
// properly when the TestFlight distribution was used. Because we couldn't find the reliable workaround,
// we decided to fallback on the legacy API for the time being.
final class LaunchOnBootLegacyAPIService: LaunchOnBootServiceProtocol {
    
    @Published var isLaunchOnBootEnabled: Bool
    var isLaunchOnBootEnabledPublisher: AnyPublisher<Bool, Never> {
        self.$isLaunchOnBootEnabled.eraseToAnyPublisher()
    }
    @Published var launchOnBootUserFacingMessage: String?
    var launchOnBootUserFacingMessagePublisher: AnyPublisher<String?, Never> {
        self.$launchOnBootUserFacingMessage.eraseToAnyPublisher()
    }
    
    @SettingsStorage("lastSavedLaunchOnBootUserPreference") private var lastSavedLaunchOnBootUserPreference: Bool?
    
    private static let launcherIdentifier = "ch.protonmail.drive.launcher.ProtonDriveMacLauncher"
    
    private var cancellables: Set<AnyCancellable> = []
    
    init() {
        self.isLaunchOnBootEnabled = LaunchOnBootLegacyAPIService.state() ?? false
        self.launchOnBootUserFacingMessage = nil
    }
    
    public func userSignedIn() {
        if let lastSavedLaunchOnBootUserPreference {
            if lastSavedLaunchOnBootUserPreference != isLaunchOnBootEnabled {
                // if the setting is different than what user has previously saved, we fix that
                setLaunchOnBootSetting(lastSavedLaunchOnBootUserPreference)
            }
        } else {
            // user has never set the preference, so we set a default to true
            setLaunchOnBootSetting(true)
        }
        
        self.$isLaunchOnBootEnabled
            .removeDuplicates()
            .sink { [unowned self] shouldStartOnBoot in
                self.setLaunchOnBootSetting(shouldStartOnBoot)
            }
            .store(in: &cancellables)
    }
    
    public func userSignedOut() {
        let userPreference = lastSavedLaunchOnBootUserPreference
        setLaunchOnBootSetting(false)
        lastSavedLaunchOnBootUserPreference = userPreference
    }
    
    fileprivate func setLaunchOnBootSetting(_ shouldStartOnBoot: Bool) {
        // no need to update anything if the value has not changed
        guard shouldStartOnBoot != isLaunchOnBootEnabled else { return }
        
        let cfString: CFString = LaunchOnBootLegacyAPIService.launcherIdentifier as CFString
        if SMLoginItemSetEnabled(cfString, shouldStartOnBoot) {
            launchOnBootUserFacingMessage = nil
        } else {
            launchOnBootUserFacingMessage = "Error setting the launch on boot state"
        }
        isLaunchOnBootEnabled = LaunchOnBootLegacyAPIService.state() ?? false
        lastSavedLaunchOnBootUserPreference = isLaunchOnBootEnabled
    }
    
    fileprivate static func state() -> Bool? {
        guard let jobs = SMCopyAllJobDictionaries(kSMDomainUserLaunchd)?.takeRetainedValue() as? [[String: AnyObject]] else {
            return nil
        }
        guard let job = jobs.first(where: { ($0["Label"] as? String) == launcherIdentifier }) else {
            return false
        }
        guard let isOn = job["OnDemand"] as? Bool else {
            return false
        }
        return isOn
    }
}
