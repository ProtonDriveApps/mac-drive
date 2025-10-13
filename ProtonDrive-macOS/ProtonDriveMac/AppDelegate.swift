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

import Cocoa
import FileProvider
import PDCore
import PDClient
import UserNotifications
import ProtonCoreFeatureFlags
import ProtonCoreServices
import ProtonCoreCryptoGoInterface
import ProtonCoreCryptoMultiversionPatchedGoImplementation
import ProtonCoreLog
import PMEventsManager

class AppDelegate: NSObject, NSApplicationDelegate {
    @SettingsStorage("firstLaunchHappened") private var firstLaunchHappened: Bool?
    @SettingsStorage(UserDefaults.FileProvider.extensionPathKey.rawValue) var fileProviderExtensionPath: String?

    private var coordinator: AppCoordinator?
    private var isTerminatingDueToAppCoordinatorError = false
    private let memoryWarningObserver: MemoryWarningObserver
    private let observationCenter: PDCore.UserDefaultsObservationCenter

    override init() {
        Log.trace()

        inject(cryptoImplementation: ProtonCoreCryptoMultiversionPatchedGoImplementation.CryptoGoMethodsImplementation.instance)
        
        // this must be done before the first access to the user defaults
        GroupContainerMigrator.instance.checkIfMigrationIsNessesary()
        GroupContainerMigrator.instance.migrateUserDefaults()
        
        self._firstLaunchHappened.configure(with: Constants.appGroup)
        self._fileProviderExtensionPath.configure(with: Constants.appGroup)

        PDFileManager.configure(with: Constants.appGroup)
        self.memoryWarningObserver = MemoryWarningObserver(memoryDiagnosticResource: DeviceMemoryDiagnosticsResource())
        self.observationCenter = UserDefaultsObservationCenter(userDefaults: Constants.appGroup.userDefaults, additionalLogging: true)

        super.init()

        setUpExtensionLaunchObserver()

#if !HAS_QA_FEATURES
        let executablePath = Bundle.main.executablePath ?? ""
        if executablePath.hasPrefix("/Applications/") == false {
            Task {
                await handleError(NSError(domain: "", code: -1, responseDictionary: nil, localizedDescription: "This application must be run from the /Applications folder. \n  Please move it there and run it again."))
            }
        }
#endif
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Calling the initializer of NSDocumentController causes its `shared`
        // instance to be returned - which includes a subclass's initializer
        // calling `super.init`. So we must initialize our desired subclass
        // before the system initializes its parent (sometime between
        // AppDelegate's `applicationWillFinishLaunching` and
        // `applicationDidFinishLaunching`).
        _ = ProtonFileController.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.trace()

        UNUserNotificationCenter.current().delegate = self
        
        // Inject build type to enable build differentiation. (Build macros don't work in SPM)
        PDCore.Constants.buildType = Constants.buildType
        
        var keychainCleared = false
        if self.firstLaunchHappened != true {
            // first launch after install is a good time for Keychain leftovers cleanup
            DriveKeychain.shared.removeEverything()
            self.firstLaunchHappened = true
            keychainCleared = true
        }
        
        Constants.loadConfiguration()
        configureCoreLogger()
        
        Task {
            do {
                coordinator = await AppCoordinator(())

                setUpLogger()

                if keychainCleared {
                    Log.info("Keychain was cleared due to firstLaunchHappened != true", domain: .application)
                }

                try await coordinator?.start()

                Log.trace("finished launching")
            } catch {
                Log.error("Starting AppCoordinator failed", error: error, domain: .application)
                await MainActor.run {
                    handleError(error)
                }
            }
        }
    }

    private func configureCoreLogger() {
        let hostSubstring = Constants.userApiConfig.environment.doh.getCurrentlyUsedHostUrl()
            .trimmingPrefix("http://").trimmingPrefix("https://")
        PMLog.setExternalLoggerHost(String(hostSubstring))
    }

    private func setUpLogger() {
        let localSettings = LocalSettings.shared
        SentryClient.shared.start(localSettings: localSettings)

        let shouldCompressLogs = self.coordinator?.featureFlags?.isEnabled(flag: .logsCompressionDisabled) ?? false
        Log.configure(system: .macOSApp, compressLogs: shouldCompressLogs)
        
        PDClient.logInfo = { Log.info($0, domain: .application) }
        PDClient.logError = { Log.error($0, domain: .application) }
        PMEventsManager.log = { Log.trace($0, file: $1, function: $2, line: $3) }

        NotificationCenter.default.addObserver(forName: .NSApplicationProtectedDataDidBecomeAvailable, object: nil, queue: nil) { _ in
            Log.info("Notification.Name.NSApplicationProtectedDataDidBecomeAvailable", domain: .application)
        }
        NotificationCenter.default.addObserver(forName: .NSApplicationProtectedDataWillBecomeUnavailable, object: nil, queue: nil) { _ in
            Log.info("Notification.Name.NSApplicationProtectedDataWillBecomeUnavailable", domain: .application)
        }
    }

    private func setUpExtensionLaunchObserver() {
        observationCenter.addObserver(self, of: \.fileProviderExtensionPath) { [weak self] extensionPath in
            guard let extensionPath = extensionPath ?? nil else {
                Log.warning("Application received FileProviderExtension launch notification without extensionPath", domain: .application)
                return
            }

            guard extensionPath.hasPrefix(Bundle.main.bundlePath) else {
                self?.presentIncorrectExtensionPathAlert(incorrectAppPath: extensionPath)
                return
            }

            Log.trace("Handled FileProviderExtension launch notification, extensionPath: \(extensionPath)", domain: .application)
        }
    }

    func applicationProtectedDataDidBecomeAvailable(_ notification: Notification) {
        Log.info("AppDelegate.applicationProtectedDataDidBecomeAvailable", domain: .application)
    }
    
    func applicationProtectedDataWillBecomeUnavailable(_ notification: Notification) {
        Log.info("AppDelegate.applicationProtectedDataWillBecomeUnavailable", domain: .application)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let currentEvent = NSAppleEventManager.shared().currentAppleEvent
        let pid = currentEvent?.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        let bundleIdentifier = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } ?? Bundle.main.bundleIdentifier
        let reason = currentEvent?.attributeDescriptor(forKeyword: kAEQuitReason)?.stringValue

        // TODO: Add observability - observability.terminated(by bundleIdentifier: bundleIdentifier)

        let sendToSentry = bundleIdentifier != Bundle.main.bundleIdentifier
                        || bundleIdentifier != "com.apple.loginwindow"
                        || reason != nil

        Log.info("AppDelegate.applicationShouldTerminate, at request of: \(bundleIdentifier ?? ""), for reason: \(reason ?? "")", domain: .application, sendToSentryIfPossible: sendToSentry)

        disconnectDomainsBeforeClosing(sender)
        return .terminateLater
    }

    func disconnectDomainsBeforeClosing(_ sender: NSApplication) {
        Task {
            try? await coordinator?.domainOperationsService.disconnectCurrentDomainBeforeAppClosing()
            if isTerminatingDueToAppCoordinatorError {
                // crashing with fatalError because calling the reply(toApplicationShouldTerminate:) was somehow hanging the app (blocking the main thread)
                // regardless of making sure it's been called only from the main thread (using DispatchQueue.main or MainActor.run)
                fatalError(ExceptionMessagesExcludedFromSentryCrashReport.appCoordinatorErrorWhileStartingApp.rawValue)
            } else {
                await MainActor.run {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

// MARK: - Error handling

extension AppDelegate {
    
    // heavily inspired by Apple's sample code (https://developer.apple.com/documentation/fileprovider/replicated_file_provider_extension/synchronizing_files_using_file_provider_extensions)
    // there's a class of errors that are user-actionable, so we want to expose them — if for nothing else, just to have more meaningful CS reports
    @MainActor
    func handleError(_ error: Error) {

        let window = coordinator?.window ?? {
            let window = NSWindow()
            window.makeKeyAndOrderFront(nil)
            window.close()
            return window
        }()

        guard let domainOperationError = error as? DomainOperationErrors
        else {
            window.presentError(error)
            return
        }
        
        let underlyingError = domainOperationError.underlyingError as NSError
        
        var showCustomerSupportButton = false
        let recoveryAttempter: RecoveryAttempter?
        let localizedDescription: String
        let recoverySuggestion: String

        switch underlyingError {
        case NSFileProviderError.providerTranslocated:
            recoveryAttempter = nil
            localizedDescription = "The application cannot be used from this location."
            recoverySuggestion = "Move the application to a different location to use it."

        case NSFileProviderError.olderExtensionVersionRunning:
            recoveryAttempter = RecoveryAttempter()
            recoveryAttempter?.option(with: "Show older version") { [weak self] error in
                guard let location = (error as NSError).userInfo[NSFilePathErrorKey] as? String else {
                    return false
                }
                NSWorkspace.shared.selectFile(location, inFileViewerRootedAtPath: location)
                self?.isTerminatingDueToAppCoordinatorError = true
                NSApp.terminate(nil)
                return true
            }
            localizedDescription = "An older version of the application is currently in use."
            recoverySuggestion = "Please move the older version to the trash before continuing."

        case NSFileProviderError.newerExtensionVersionFound:
            recoveryAttempter = RecoveryAttempter()
            recoveryAttempter?.option(with: "Show newer version") { [weak self] error in
                guard let location = (error as NSError).userInfo[NSFilePathErrorKey] as? String else {
                    return false
                }
                NSWorkspace.shared.selectFile(location, inFileViewerRootedAtPath: location)
                self?.isTerminatingDueToAppCoordinatorError = true
                NSApp.terminate(nil)
                return true
            }
            localizedDescription = "A newer version of the application is already installed."
            recoverySuggestion = "Please use the newer version instead."

        case NSFileProviderError.providerNotFound:
            recoveryAttempter = nil
            localizedDescription = "Unable to start file provider extension"
            recoverySuggestion = "Please ensure you do not have two Proton Drive apps installed. \n" +
                "If this is the case, remove the one outside the /Applications folder. \n\n" +
                "If the issue persists, please contact Customer Support. "

            showCustomerSupportButton = true

        default:
            recoveryAttempter = nil
            localizedDescription = underlyingError.localizedDescription
            recoverySuggestion = underlyingError.localizedRecoverySuggestion ?? ""
        }
        
        var errorToPresent = NSError(underlyingError, adding: [
            NSLocalizedDescriptionKey: localizedDescription,
            NSLocalizedRecoverySuggestionErrorKey: recoverySuggestion
        ])
        
        if let recoveryAttempter {
            errorToPresent = NSError(errorToPresent, adding: [
                NSLocalizedRecoveryOptionsErrorKey: recoveryAttempter.localizedRecoveryOptions,
                NSRecoveryAttempterErrorKey: recoveryAttempter
            ])
        }

        if showCustomerSupportButton {
            presentErrorWithCustomerSupportButton(error: errorToPresent)
        } else {
            window.presentError(errorToPresent)
        }

        guard recoveryAttempter == nil else { return }
        isTerminatingDueToAppCoordinatorError = true
        NSApp.terminate(nil)
    }

    private func presentErrorWithCustomerSupportButton(error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = error.localizedDescription
        alert.informativeText = error.asAFError?.recoverySuggestion ?? ""

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Contact Support")

        let response = alert.runModal()
        switch response {
        case .alertSecondButtonReturn:
            UserActions(delegate: nil).links.showSupportWebsite()
        default:
            break
        }
    }

    private func presentIncorrectExtensionPathAlert(incorrectAppPath: String) {
        let alert = NSAlert()

        alert.messageText = "FileProvider has launched from outside the current Drive app."
        alert.informativeText = "Please ensure you do not have two Proton Drive apps installed. \n" +
        "If this is the case, remove the one outside the /Applications folder. \n\n" +
        "If the issue persists, please contact Customer Support. "

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Contact Support")

        // best-effort attempt to get the path that contains the old/wrong Drive app
        // this should cover 99% of cases - if the app's been renamed, we'll
        // still show the error but users will have to figure out where the app is themselves.
        let defaultAppName = "Proton Drive.app"
        let appPathComponents = incorrectAppPath.split(separator: defaultAppName)

        if appPathComponents.first != nil {
            alert.addButton(withTitle: "Show me the wrong app")
        }

        let response = alert.runModal()

        switch response {
        case .alertSecondButtonReturn:
            UserActions(delegate: nil).links.showSupportWebsite()
        case .alertThirdButtonReturn:
            if let pathContainingApp = appPathComponents.first.map({ String($0) }) {
                NSWorkspace.shared.selectFile(pathContainingApp + defaultAppName, inFileViewerRootedAtPath: pathContainingApp)
            }
        default:
            break
        }
    }
}

private extension NSError {
    // Merge values into the user info values from the error. If values to add
    // contain keys that already exist, this method overwrites the existing
    // values.
    convenience init(_ other: Error, adding valuesToAdd: [String: Any]) {
        let nsError = other as NSError
        var userInfo = nsError.userInfo
        userInfo.merge(valuesToAdd, uniquingKeysWith: { $1 })
        self.init(domain: nsError.domain, code: nsError.code, userInfo: userInfo)
    }
}
