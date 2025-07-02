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

import AppKit
import Combine
import PDCore
import SwiftUI
import PDLocalization

extension UserInfo {
    var storageDescription: String {
        let currentStorage = ByteCountFormatter.storageSizeString(forByteCount: usedSpace)
        let maxStorage = ByteCountFormatter.storageSizeString(forByteCount: maxSpace)
        return Localization.setting_storage_usage_info(currentStorage: currentStorage, maxStorage: maxStorage)
    }
}

protocol SettingsViewModelProtocol: ObservableObject {
    var initials: String { get }
    var displayName: String { get }
    var emailAddress: String { get }
    var userInfo: UserInfo { get }
    static var supportWebsiteURL: URL { get }
    var version: String { get }
    var isSignoutInProgress: Bool { get }
    var isLaunchOnBootEnabled: Bool { get set }
    var isFullResyncEnabled: Bool { get }
    var launchOnBootUserFacingMessage: String? { get }
    var actions: UserActions { get }
    #if HAS_BUILTIN_UPDATER
    var updateAvailability: UpdateAvailabilityStatus { get }
    #endif
}

final class SettingsViewModel: SettingsViewModelProtocol {

    var initials: String { accountInfo.displayName.initials() }
    var displayName: String { accountInfo.displayName }
    var emailAddress: String { accountInfo.email }

    let version: String = Constants.versionDigits

    @Published var userInfo: UserInfo
    @Published var isSignoutInProgress: Bool = false
    #if HAS_BUILTIN_UPDATER
    @Published var updateAvailability: UpdateAvailabilityStatus
    #endif

    static let supportWebsiteURL: URL = URL(string: "https://proton.me/support/drive")!

    private let sessionVault: SessionVault
    private let launchOnBootService: LaunchOnBootServiceProtocol
    private var appUpdateService: AppUpdateServiceProtocol?
    private let accountInfo: AccountInfo

    @Published var isLaunchOnBootEnabled: Bool
    @Published var launchOnBootUserFacingMessage: String?
    @Published var isFullResyncEnabled: Bool
    private var cancellables: Set<AnyCancellable> = []

    let actions: UserActions

    init(sessionVault: SessionVault,
         launchOnBootService: LaunchOnBootServiceProtocol,
         appUpdateService: AppUpdateServiceProtocol?,
         userActions: UserActions,
         isFullResyncEnabled: Bool) {
        self.launchOnBootService = launchOnBootService
        self.appUpdateService = appUpdateService
        self.actions = userActions

        guard let accountInfo = sessionVault.getAccountInfo(),
              let userInfo = sessionVault.getUserInfo()
        else {
            fatalError("Can't show account settings because account or user info missing")
        }

        self.userInfo = userInfo
        self.accountInfo = accountInfo
        self.sessionVault = sessionVault

        self.isLaunchOnBootEnabled = launchOnBootService.isLaunchOnBootEnabled
        self.launchOnBootUserFacingMessage = launchOnBootService.launchOnBootUserFacingMessage
        
        self.isFullResyncEnabled = isFullResyncEnabled

#if HAS_BUILTIN_UPDATER
        self.updateAvailability = appUpdateService?.updateAvailability ?? .upToDate(version: "")
#endif

        subscribeToNotifications()
    }
    
    private func subscribeToNotifications() {
        sessionVault.userInfoPublisher
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] userInfo in
                self.userInfo = userInfo
            }
            .store(in: &cancellables)
        
        self.$isLaunchOnBootEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] in
                launchOnBootService.isLaunchOnBootEnabled = $0
            }
            .store(in: &cancellables)
        
        launchOnBootService.launchOnBootUserFacingMessagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] in
                self.launchOnBootUserFacingMessage = $0
            }
            .store(in: &cancellables)

        #if HAS_BUILTIN_UPDATER
        appUpdateService?.updateAvailabilityPublisher
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] in
                self.updateAvailability = $0
            }
            .store(in: &cancellables)
        #endif
    }

    func signOut() {
        isSignoutInProgress = true
        Task { [weak self] in
            self?.actions.account.userRequestedSignOut()
            await MainActor.run { [weak self] in
                self?.isSignoutInProgress = false
            }
        }
    }
}
