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
    func signInUsingTestCredentials(login: String, password: String)

    // Promo
    func dismissPromoBanner()

    // Sync
    func pauseSyncing()
    func resumeSyncing()
    func togglePausedStatus()
    func cleanUpErrors() async

    // Resync
    func performFullResync(onlyIfPreviouslyInterrupted: Bool)
    func finishFullResync()
    func retryFullResync()
    func cancelFullResync()

    // Windows
    func showLogin()
    func showErrorWindow()
    func showLogsInFinder() async throws
    func showLogsWhenNotConnected()
    func showSettings()
    func closeOnboardingWindow()
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
    func toggleGlobalProgressStatusItem()
#endif
}

/// Handlers for user actions performed throughout the application (i.e. whenever the user presses a button, or similar).
/// Actions which don't require any context are implemented here directly.
/// Others are called via `AppCoordinator` (as `delegate`).
class UserActions {
    private weak var delegate: UserActionsDelegate?

    lazy var app = ApplicationActions(delegate: delegate)
    lazy var promo = PromotionalActions(delegate: delegate)
    lazy var account = AccountActions(delegate: delegate)
    lazy var sync = SyncActions(delegate: delegate)
    lazy var resync = ResyncActions(delegate: delegate)
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
            Log.userAction(["buttonIsNil": "\(button == nil)", "onlyOpen": onlyOpen])
            delegate?.toggleStatusWindow(from: button, onlyOpen: onlyOpen)
        }

        func showStatusWindow(from button: NSButton? = nil) {
            Log.userAction(["buttonIsNil": "\(button == nil)"])
            delegate?.showStatusWindow(from: button)
        }

        @objc func openDriveFolder(fileLocation: String? = nil) {
            Log.userAction(["fileLocation": fileLocation])
            delegate?.openDriveFolder(fileLocation: fileLocation)
        }

        func closeOnboardingWindow() {
            Log.userAction()
            delegate?.closeOnboardingWindow()
        }

        func toggleDetailedLogging() {
            Log.userAction()
            delegate?.toggleDetailedLogging()
        }

#if HAS_BUILTIN_UPDATER
        @objc func installUpdate() {
            Log.userAction()
            delegate?.installUpdate()
        }

        func checkForUpdates() {
            Log.userAction()
            delegate?.checkForUpdates()
        }
#endif

        @objc func quitApp() {
            Log.userAction()
            NSApp.terminate(self)
        }

        func restartApp() {
            Log.userAction()
            scheduleAppRelaunch(afterDelay: 3)
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
            Log.userAction()
            assert(delegate != nil)
            Task {
                await delegate?.userRequestedSignOut()
            }
        }

        func signInUsingTestCredentials(login: String, password: String) {
            assert(delegate != nil)
            delegate?.signInUsingTestCredentials(login: login, password: password)
        }

        func refreshUserInfo() {
            Log.userAction()
            assert(delegate != nil)
            delegate?.refreshUserInfo()
        }
    }

    class PromotionalActions {
        private weak var delegate: UserActionsDelegate?

        init(delegate: UserActionsDelegate?) {
            self.delegate = delegate
        }

        func dismissPromoBanner() {
            Log.userAction()
            delegate?.dismissPromoBanner()
        }

        func goToPromoPageOnWeb(email: String?) {
            // reuse LinkActions to go to drive dashboard
            Log.userAction(["email": email])
            LinkActions().getMoreStorage(email: email)
        }
    }

    class SyncActions {
        private weak var delegate: UserActionsDelegate?

        init(delegate: UserActionsDelegate?) {
            self.delegate = delegate
        }

        @objc func pauseSyncing()  {
            Log.userAction()
            delegate?.pauseSyncing()
        }

        @objc func resumeSyncing()  {
            Log.userAction()
            delegate?.resumeSyncing()
        }

        func togglePausedStatus() {
            Log.userAction()
            delegate?.togglePausedStatus()
        }

        func cleanUpErrors() async {
            Log.userAction()
            await delegate?.cleanUpErrors()
        }
    }

    class ResyncActions {
        private weak var delegate: UserActionsDelegate?

        init(delegate: UserActionsDelegate?) {
            self.delegate = delegate
        }

        func performFullResync(onlyIfPreviouslyInterrupted: Bool = false) {
            Log.userAction(["onlyIfPreviouslyInterrupted": onlyIfPreviouslyInterrupted])
            delegate?.performFullResync(onlyIfPreviouslyInterrupted: onlyIfPreviouslyInterrupted)
        }

        func finishFullResync() {
            Log.userAction()
            delegate?.finishFullResync()
        }

        func retryFullResync() {
            Log.userAction()
            delegate?.retryFullResync()
        }

        @objc func cancelFullResync() {
            Log.userAction()
            delegate?.cancelFullResync()
        }
    }

    class WindowActions {
        private weak var delegate: UserActionsDelegate?

        init(delegate: UserActionsDelegate?) {
            self.delegate = delegate
        }

        @objc func showLogin() {
            Log.userAction()
            delegate?.showLogin()
        }

        @objc func showErrorWindow() {
            Log.userAction()
            delegate?.showErrorWindow()
        }

        func showLogsInFinder() {
            Log.userAction()
            Task {
                try await delegate?.showLogsInFinder()
            }
        }

        @objc func showLogsWhenNotConnected() {
            Log.userAction()
            delegate?.showLogsWhenNotConnected()
        }

        @objc func showSettings() {
            Log.userAction()
            delegate?.showSettings()
        }

        func closeOnboardingWindow() {
            Log.userAction()
            delegate?.closeOnboardingWindow()
        }

        func closeSettingsAndShowMainWindow() {
            Log.userAction()
            delegate?.closeSettingsAndShowMainWindow()
        }

#if HAS_QA_FEATURES
        @objc func showQASettings() {
            Log.userAction()
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
            Log.userAction(["url": url.absoluteString])
            _ = NSWorkspace.shared.open(url)
        }

        func openOnlineDriveFolder(email: String?, folder: String? = nil) {
            Log.userAction(["email": AnyEncodable(email), "folder": folder])
            var url = driveWebsiteURL.appending(email: email)
            if let folder {
                url.appendPathComponent(folder)
            }
            open(url: url)
        }

        func showSupportWebsite() {
            Log.userAction()
            open(url: SettingsViewModel.supportWebsiteURL)
        }

        func manageAccount(email: String?) {
            Log.userAction()
            open(url: manageAccountURL.appending(email: email))
        }

        func getMoreStorage(email: String?) {
            Log.userAction()
            open(url: getMoreStorageURL.appending(email: email))
        }

        func showTermsAndConditions() {
            Log.userAction()
            open(url: termsAndConditionsURL)
        }

        @objc func reportBug() {
            Log.userAction()
            open(url: reportBugURL)
        }

        func showReleaseNotes() {
            Log.userAction()
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
            Log.userAction(["paths": paths])
            delegate?.keepDownloaded(paths: paths)
        }
        func keepOnlineOnly(paths: [String]) {
            Log.userAction(["paths": paths])
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
            Log.userAction()
            delegate?.showQASettings()
        }

        @MainActor @objc func toggleGlobalProgressStatusItem() {
            Log.userAction()
            delegate?.toggleGlobalProgressStatusItem()
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

extension URL {
    fileprivate func appending(email: String?) -> URL {
        if let email {
            return self.appending(queryItems: [URLQueryItem(name: "email", value: email)])
        }
        return self
    }
}
