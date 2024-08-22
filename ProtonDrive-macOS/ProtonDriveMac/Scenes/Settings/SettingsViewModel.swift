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

protocol SettingsViewModelDelegate: AnyObject {
    func reportIssue()
    func showLogsInFinder() async throws
    func showReleaseNotes()
    func userRequestedSignOut() async
}

protocol SettingsViewModelProtocol: ObservableObject {
    var currentStorageInBytes: Int64 { get }
    var maxStorageInBytes: Int64 { get }
    var initials: String { get }
    var displayName: String { get }
    var emailAddress: String { get }
    var supportWebsiteURL: URL { get }
    var version: String { get }
    var isStorageWarning: Bool { get }
    var isStorageFull: Bool { get }
    var isLoadingLogs: Bool { get }
    var isSignoutInProgress: Bool { get }
    var isLaunchOnBootEnabled: Bool { get set }
    var launchOnBootUserFacingMessage: String? { get }
    #if HAS_BUILTIN_UPDATER
    var updateAvailability: UpdateAvailabilityStatus { get }
    #endif

    func getMoreStorage()
    func manageAccount()
    func reportIssue()
    func showLogsInFinder() async throws
    func showSupportWebsite()
    func showTermsAndConditions()
    func showReleaseNotes()
    func signOut()
    #if HAS_BUILTIN_UPDATER
    func installUpdate()
    func checkForUpdates()
    #endif
}

final class SettingsViewModel: SettingsViewModelProtocol {

    var initials: String { accountInfo.displayName.initials() }
    var displayName: String { accountInfo.displayName }
    var emailAddress: String { accountInfo.email }

    let version: String = Constants.versionDigits

    @Published var currentStorageInBytes: Int64
    @Published var maxStorageInBytes: Int64
    @Published var isStorageWarning: Bool
    @Published var isStorageFull: Bool
    @Published var isLoadingLogs: Bool = false
    @Published var isSignoutInProgress: Bool = false
    #if HAS_BUILTIN_UPDATER
    @Published var updateAvailability: UpdateAvailabilityStatus
    #endif

    let supportWebsiteURL: URL = URL(string: "https://proton.me/support/drive")!
    private let manageAccountURL: URL = URL(string: "https://account.proton.me/drive/account-password")!
    private let getMoreStorageURL: URL = URL(string: "https://account.proton.me/drive/dashboard")!
    private let termsAndConditionsURL: URL = URL(string: "https://proton.me/legal/terms-ios")!

    private let sessionVault: SessionVault
    private let launchOnBootService: LaunchOnBootServiceProtocol
    #if HAS_BUILTIN_UPDATER
    private var appUpdateService: any AppUpdateServiceProtocol
    #endif
    private let accountInfo: AccountInfo

    @Published var isLaunchOnBootEnabled: Bool
    @Published var launchOnBootUserFacingMessage: String?
    private var cancellables: Set<AnyCancellable> = []
    
    private weak var delegate: SettingsViewModelDelegate?
    #if HAS_BUILTIN_UPDATER
    init(delegate: SettingsViewModelDelegate?,
         sessionVault: SessionVault,
         launchOnBootService: LaunchOnBootServiceProtocol,
         appUpdateService: AppUpdateServiceProtocol) {

        self.delegate = delegate
        self.launchOnBootService = launchOnBootService
        self.appUpdateService = appUpdateService

        guard let accountInfo = sessionVault.getAccountInfo(),
              let userInfo = sessionVault.getUserInfo()
        else {
            fatalError("Can't show account settings because account or user info missing")
        }
        
        self.currentStorageInBytes = Int64(userInfo.usedSpace)
        self.maxStorageInBytes = Int64(userInfo.maxSpace)
        self.isStorageWarning = SettingsViewModel.calculateStorageWarning(userInfo)
        self.isStorageFull = SettingsViewModel.calculateStorageFull(userInfo)

        self.accountInfo = accountInfo
        self.sessionVault = sessionVault

        self.isLaunchOnBootEnabled = launchOnBootService.isLaunchOnBootEnabled
        self.launchOnBootUserFacingMessage = launchOnBootService.launchOnBootUserFacingMessage

        self.updateAvailability = appUpdateService.updateAvailability

        subscribeToNotifications()
    }
    #else
    init(delegate: SettingsViewModelDelegate?,
         sessionVault: SessionVault,
         launchOnBootService: LaunchOnBootServiceProtocol) {

        self.delegate = delegate
        self.launchOnBootService = launchOnBootService

        guard let accountInfo = sessionVault.getAccountInfo(),
              let userInfo = sessionVault.getUserInfo()
        else {
            fatalError("Can't show account settings because account or user info missing")
        }
        
        self.currentStorageInBytes = Int64(userInfo.usedSpace)
        self.maxStorageInBytes = Int64(userInfo.maxSpace)
        self.isStorageWarning = SettingsViewModel.calculateStorageWarning(userInfo)
        self.isStorageFull = SettingsViewModel.calculateStorageFull(userInfo)

        self.accountInfo = accountInfo
        self.sessionVault = sessionVault

        self.isLaunchOnBootEnabled = launchOnBootService.isLaunchOnBootEnabled
        self.launchOnBootUserFacingMessage = launchOnBootService.launchOnBootUserFacingMessage
        
        subscribeToNotifications()
    }
    #endif
    
    private func subscribeToNotifications() {
        sessionVault.userInfoPublisher
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] userInfo in
                self.currentStorageInBytes = Int64(userInfo.usedSpace)
                self.maxStorageInBytes = Int64(userInfo.maxSpace)
                self.isStorageWarning = SettingsViewModel.calculateStorageWarning(userInfo)
                self.isStorageFull = SettingsViewModel.calculateStorageFull(userInfo)
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
        appUpdateService.updateAvailabilityPublisher
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] in
                self.updateAvailability = $0
            }
            .store(in: &cancellables)
        #endif
    }
    
    private static func calculateStorageWarning(_ userInfo: UserInfo) -> Bool {
        userInfo.usedSpace / userInfo.maxSpace > 0.8
    }
    
    private static func calculateStorageFull(_ userInfo: UserInfo) -> Bool {
        userInfo.availableStorage == 0
    }

    func manageAccount() {
        open(url: manageAccountURL)
    }

    func getMoreStorage() {
        open(url: getMoreStorageURL)
    }

    func reportIssue() {
        delegate?.reportIssue()
    }

    @MainActor
    func showLogsInFinder() async throws {
        isLoadingLogs = true
        do {
            try await delegate?.showLogsInFinder()
            Log.info("Showing Logs in Finder succeeded", domain: .fileManager)
            isLoadingLogs = false
        } catch {
            Log.error("Failed to show Logs in Finder: \(error.localizedDescription)", domain: .fileManager)
            isLoadingLogs = false
        }
    }

    func showSupportWebsite() {
        open(url: supportWebsiteURL)
    }

    func signOut() {
        isSignoutInProgress = true
        Task { [weak self] in
            await self?.delegate?.userRequestedSignOut()
            await MainActor.run { [weak self] in
                self?.isSignoutInProgress = false
            }
        }
    }

    func showTermsAndConditions() {
        open(url: termsAndConditionsURL)
    }
    
    func showReleaseNotes() {
        delegate?.showReleaseNotes()
    }
    
    #if HAS_BUILTIN_UPDATER
    func installUpdate() {
        appUpdateService.installUpdateIfAvailable()
    }
    
    func checkForUpdates() {
        appUpdateService.checkForUpdates()
    }
    #endif

    private func open(url: URL) {
        _ = NSWorkspace.shared.open(url)
    }
}
