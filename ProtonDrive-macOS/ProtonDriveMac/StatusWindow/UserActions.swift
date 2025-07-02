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
import AppKit
import PDCore

/// User actions which are implemented in `AppCoordinator` - see `UserActions` for details.
@objc protocol UserActionsDelegate {
    // Application
    func toggleStatusWindow(from button: NSButton?, onlyOpen: Bool)
    func showStatusWindow(from button: NSButton?)
#if HAS_BUILTIN_UPDATER
    func installUpdate()
    func checkForUpdates()
#endif

    // Account
    func userRequestedSignOut() async
    func refreshUserInfo()
    func signInUsingTestCredentials(email: String, password: String)

    // Sync
    func pauseSyncing()
    func resumeSyncing()
    func togglePausedStatus()
    func cleanUpErrors()
    func performFullResync(onlyIfPreviouslyInterrupted: Bool)
    func finishFullResync()
    func retryFullResync()
    func cancelFullResync()
    func abortFullResync()

    // Windows
    func showLogin()
    func showErrorWindow()
    func showLogsInFinder() async throws
    func showLogsWhenNotConnected()
    func showSettings()
    func closeSettingsAndShowMainWindow()
    func openDriveFolder(fileLocation: String?)
    
    // FileProvider
    func keepDownloaded(paths: [String])
    func keepOnlineOnly(paths: [String])

    // Other
    func toggleDetailedLogging()

    // Debugging
#if HAS_QA_FEATURES
    func showQASettings()
    func toggleGlobalProgressStatusItem() async
#endif
}

/// Handlers for user actions performed throughout the application (i.e. whenever the user presses a button, or similar).
/// Actions which don't require any context are implemented here directly.
/// Others are called via `AppCoordinator` (as `delegate`).
class UserActions {
    private weak var delegate: UserActionsDelegate?

    lazy var app = ApplicationActions(delegate: delegate)
    lazy var account = AccountActions(delegate: delegate)
    lazy var sync = SyncActions(delegate: delegate)
    lazy var windows = WindowActions(delegate: delegate)
    lazy var links = LinkActions()
    lazy var fileProvider = FileProviderActions(delegate: delegate)

#if HAS_QA_FEATURES
    lazy var debugging = DebuggingActions(delegate: delegate)

    var mocks: MockActions?
    private weak var observer: ApplicationEventObserver?
    // Observer only needs to be passed in if we want to use MockActions
    init(delegate: UserActionsDelegate?, observer: ApplicationEventObserver? = nil) {
        self.delegate = delegate
        if let observer {
            self.mocks = MockActions(observer: observer)
        }
    }
#else
    init(delegate: UserActionsDelegate?) {
        self.delegate = delegate
    }
#endif

    class ApplicationActions {
        private weak var delegate: UserActionsDelegate?

        init(delegate: UserActionsDelegate?) {
            self.delegate = delegate
        }

        func toggleStatusWindow(from button: NSButton? = nil, onlyOpen: Bool = false) {
            Log.trace()
            delegate?.toggleStatusWindow(from: button, onlyOpen: onlyOpen)
        }

        func showStatusWindow(from button: NSButton? = nil) {
            Log.trace()
            delegate?.showStatusWindow(from: button)
        }

        @objc func openDriveFolder(fileLocation: String? = nil) {
            Log.trace()
            delegate?.openDriveFolder(fileLocation: fileLocation)
        }

        func toggleDetailedLogging() {
            Log.trace()
            delegate?.toggleDetailedLogging()
        }

#if HAS_BUILTIN_UPDATER
        @objc func installUpdate() {
            Log.trace()
            delegate?.installUpdate()
        }

        func checkForUpdates() {
            Log.trace()
            delegate?.checkForUpdates()
        }
#endif

        @objc func quitApp() {
            Log.trace()
            NSApp.terminate(self)
        }

        @objc func doNothing() {}
    }

    class AccountActions {
        private weak var delegate: UserActionsDelegate?

        init(delegate: UserActionsDelegate?) {
            self.delegate = delegate
        }

        @objc func userRequestedSignOut() {
            Log.trace()
            assert(delegate != nil)
            Task {
                await delegate?.userRequestedSignOut()
            }
        }

        func signInUsingTestCredentials(email: String, password: String) {
            assert(delegate != nil)
            delegate?.signInUsingTestCredentials(email: email, password: password)
        }

        func refreshUserInfo() {
            Log.trace()
            assert(delegate != nil)
            delegate?.refreshUserInfo()
        }
    }

    class SyncActions {
        private weak var delegate: UserActionsDelegate?

        init(delegate: UserActionsDelegate?) {
            self.delegate = delegate
        }

        @objc func pauseSyncing()  {
            Log.trace()
            delegate?.pauseSyncing()
        }

        @objc func resumeSyncing()  {
            Log.trace()
            delegate?.resumeSyncing()
        }

        func togglePausedStatus() {
            Log.trace()
            delegate?.togglePausedStatus()
        }

        func cleanUpErrors() {
            Log.trace()
            delegate?.cleanUpErrors()
        }

        func performFullResync(onlyIfPreviouslyInterrupted: Bool = false) {
            Log.trace()
            delegate?.performFullResync(onlyIfPreviouslyInterrupted: onlyIfPreviouslyInterrupted)
        }
        
        func finishFullResync() {
            Log.trace()
            delegate?.finishFullResync()
        }
        
        func retryFullResync() {
            Log.trace()
            delegate?.retryFullResync()
        }
        
        func cancelFullResync() {
            Log.trace()
            delegate?.cancelFullResync()
        }
        
        func abortFullResync() {
            Log.trace()
            delegate?.abortFullResync()
        }
    }

    class WindowActions {
        private weak var delegate: UserActionsDelegate?

        init(delegate: UserActionsDelegate?) {
            self.delegate = delegate
        }

        @objc func showLogin() {
            Log.trace()
            delegate?.showLogin()
        }

        @objc func showErrorWindow() {
            Log.trace()
            delegate?.showErrorWindow()
        }

        func showLogsInFinder() {
            Log.trace()
            Task {
                try await delegate?.showLogsInFinder()
            }
        }

        @objc func showLogsWhenNotConnected() {
            Log.trace()
            delegate?.showLogsWhenNotConnected()
        }

        @objc func showSettings() {
            Log.trace()
            delegate?.showSettings()
        }
        
        func closeSettingsAndShowMainWindow() {
            Log.trace()
            delegate?.closeSettingsAndShowMainWindow()
        }

#if HAS_QA_FEATURES
        @objc func showQASettings() {
            Log.trace()
            delegate?.showQASettings()
        }
#endif

    }

    class LinkActions {
        private let driveWebsiteURL: URL = URL(string: "https://drive.proton.me")!
        private let manageAccountURL: URL = URL(string: "https://account.proton.me/drive/account-password")!
        private let getMoreStorageURL: URL = URL(string: "https://account.proton.me/drive/dashboard")!
        private let termsAndConditionsURL: URL = URL(string: "https://proton.me/legal/terms-ios")!
        private let reportBugURL = URL(string: "https://proton.me/support/contact")!

        private func open(url: URL) {
            Log.trace()
            _ = NSWorkspace.shared.open(url)
        }

        func openOnlineDriveFolder(email: String?, folder: String? = nil) {
            Log.trace()
            var url = driveWebsiteURL
            if let email {
                url.append(queryItems: [URLQueryItem(name: "email", value: email)])
            }
            if let folder {
                url.appendPathComponent(folder)
            }
            open(url: url)
        }

        func showSupportWebsite() {
            Log.trace()
            open(url: SettingsViewModel.supportWebsiteURL)
        }

        func manageAccount() {
            Log.trace()
            open(url: manageAccountURL)
        }

        func getMoreStorage() {
            Log.trace()
            open(url: getMoreStorageURL)
        }

        func showTermsAndConditions() {
            Log.trace()
            open(url: termsAndConditionsURL)
        }

        @objc func reportBug() {
            Log.trace()
            open(url: reportBugURL)
        }

        func showReleaseNotes() {
            Log.trace()
            Task { @MainActor in
                ReleaseNotesCoordinator().start()
            }
        }
    }
    
    class FileProviderActions {
        private weak var delegate: UserActionsDelegate?

        init(delegate: UserActionsDelegate?) {
            self.delegate = delegate
        }

        func keepDownloaded(paths: [String]) {
            delegate?.keepDownloaded(paths: paths)
        }
        func keepOnlineOnly(paths: [String]) {
            delegate?.keepOnlineOnly(paths: paths)
        }
    }

#if HAS_QA_FEATURES
    class DebuggingActions {
        private weak var delegate: UserActionsDelegate?

        init(delegate: UserActionsDelegate?) {
            self.delegate = delegate
        }

        @objc func showQASettings() {
            Log.trace()
            delegate?.showQASettings()
        }

        @objc func toggleGlobalProgressStatusItem() async {
            Log.trace()
            await delegate?.toggleGlobalProgressStatusItem()
        }
    }

    class MockActions {
        private weak var observer: ApplicationEventObserver?

        init(observer: ApplicationEventObserver) {
            self.observer = observer
        }

        func mockLogout() {
            observer?.mockLogout()
        }

        func mockLogin() {
            observer?.mockLogin()
        }
        
        func mockErrorState() {
            observer?.mockErrorState()
        }

        func mockOfflineStatus(offline: Bool) {
            observer?.mockOfflineStatus(offline: offline)
        }

#if HAS_BUILTIN_UPDATER
        func mockUpdateAvailability(available: Bool) {
            observer?.mockUpdateAvailability(available: available)
        }
#endif
    }

#endif
}
