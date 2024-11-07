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
import GoLibs
import PDCore
import PDClient
import PDLoadTesting
import UserNotifications
import ProtonCoreFeatureFlags
import ProtonCoreServices
import ProtonCoreCryptoPatchedGoImplementation
import ProtonCoreLog

#if LOAD_TESTING && SSL_PINNING
#error("Load testing requires turning off SSL pinning, so it cannot be set for SSL-pinning targets")
#endif

class AppDelegate: NSObject, NSApplicationDelegate {
    @SettingsStorage("firstLaunchHappened") private var firstLaunchHappened: Bool?
    private lazy var coordinator = AppCoordinator()
    private var isTerminatingDueToAppCoordinatorError = false
    private let memoryWarningObserver: MemoryWarningObserver

    override init() {
        injectDefaultCryptoImplementation()
        
        // this must be done before the first access to the user defaults
        GroupContainerMigrator.instance.checkIfMigrationIsNessesary()
        GroupContainerMigrator.instance.migrateUserDefaults()
        
        self._firstLaunchHappened.configure(with: Constants.appGroup)
        PDFileManager.configure(with: Constants.appGroup)
        self.memoryWarningObserver = MemoryWarningObserver(memoryDiagnosticResource: DeviceMemoryDiagnosticsResource())

        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Calling the initializer of NSDocumentController causes its `shared`
        // instance to be returned - which includes a subclass's initializer
        // calling `super.init`. So we must initialize our desired subclass
        // before the system initializes its parent (sometime between
        // AppDelegate's `applicationWillFinishLaunching` and
        // `applicationDidFinishLaunching`).
        _ = ProtonDocumentController.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        
        // Inject build type to enable build differentiation. (Build macros don't work in SPM)
        PDCore.Constants.buildType = Constants.buildType
        #if LOAD_TESTING && !SSL_PINNING
        LoadTesting.enableLoadTesting()
        #endif
        
        var keychainCleared = false
        if self.firstLaunchHappened != true {
            // first launch after install is a good time for Keychain leftovers cleanup
            DriveKeychain.shared.removeEverything()
            self.firstLaunchHappened = true
            keychainCleared = true
        }
        
        Constants.loadConfiguration()
        configureCoreLogger()
        setUpLogger { [weak self] in self?.coordinator.client }
        if keychainCleared {
            Log.info("Keychain was cleared due to firstLaunchHappened != true", domain: .application)
        }

        Log.info("AppDelegate did launch", domain: .application)
        
        Task {
            do {
                try await coordinator.start()
            } catch {
                    Log.error("\(error.localizedDescription)", domain: .application)
                await MainActor.run {
                    handleError(error)
                }
            }
        }
    }

    private func configureCoreLogger() {
        let environment: String
        switch Constants.userApiConfig.environment {
        case .black, .blackPayment: environment = "black"
        case .custom(let custom): environment = custom
        default: environment = "production"
        }
        PMLog.setEnvironment(environment: environment)
    }

    private func setUpLogger(clientGetter: @escaping () -> PDClient.Client?) {
        let localSettings = LocalSettings(suite: Constants.appGroup)
        SentryClient.shared.start(localSettings: localSettings, clientGetter: clientGetter)
        Log.configuration = LogConfiguration(system: .macOSApp)
        
        #if LOAD_TESTING
        Log.logger = CompoundLogger(loggers: [
            OrFilteredLogger(logger: DebugLogger(),
                             domains: [.loadTesting],
                             levels: [.info, .error, .warning]),
            FileLogger(process: .macOSApp) { [weak self] in
                self?.coordinator.featureFlags?.isEnabled(flag: .logsCompressionDisabled) ?? false
            }
        ])
        #elseif PRODUCTION_LEVEL_LOGS
        Log.logger = CompoundLogger(loggers: [
            ProductionLogger(),
            OrFilteredLogger(logger: FileLogger(process: .macOSApp) { [weak self] in
                self?.coordinator.featureFlags?.isEnabled(flag: .logsCompressionDisabled) ?? false
            }, levels: [.info, .error, .warning])
        ])
        #else
        Log.logger = CompoundLogger(loggers: [
            OrFilteredLogger(logger: DebugLogger(),
                             domains: [.application,
                                       .encryption,
                                       .events,
                                       .networking,
                                       .uploader,
                                       .downloader,
                                       .storage,
                                       .clientNetworking,
                                       .featureFlags,
                                       .forceRefresh,
                                       .syncing,
                                       .sessionManagement,
                                       .diagnostics,
                                       .fileProvider,
                                       .fileManager,
                                       .protonDocs],
                             levels: [.info, .error, .warning]),
            FileLogger(process: .macOSApp) { [weak self] in
                self?.coordinator.featureFlags?.isEnabled(flag: .logsCompressionDisabled) ?? false
            }
        ])
        #endif
        
        PDClient.log = { Log.info($0, domain: .clientNetworking) }
        
        NotificationCenter.default.addObserver(forName: .NSApplicationProtectedDataDidBecomeAvailable, object: nil, queue: nil) { notificaiton in
            Log.info("Notification.Name.NSApplicationProtectedDataDidBecomeAvailable", domain: .application)
        }
        NotificationCenter.default.addObserver(forName: .NSApplicationProtectedDataWillBecomeUnavailable, object: nil, queue: nil) { notificaiton in
            Log.info("Notification.Name.NSApplicationProtectedDataWillBecomeUnavailable", domain: .application)
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
            try? await coordinator.domainOperationsService.disconnectDomainBeforeAppClosing()
            if isTerminatingDueToAppCoordinatorError {
                // crashing with fatalError because calling the reply(toApplicationShouldTerminate:) was somehow hanging the app (blocking the main thread)
                // regardless of making sure it's been called only from the main thread (using DispatchQueue.main or MainActor.run)
                fatalError("Terminate after domains disconnection")
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
        
        let window = coordinator.window ?? {
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
        
        let recoveryAttempter: RecoveryAttempter?
        let localizedDescription: String
        let recoverySugestion: String
        
        switch underlyingError {
        case NSFileProviderError.providerTranslocated:
            recoveryAttempter = nil
            localizedDescription = "The application cannot be used from this location."
            recoverySugestion = "Move the application to a different location to use it."
            
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
            recoverySugestion = "Please move the older version to the trash before continuing."
            
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
            recoverySugestion = "Please use the newer version instead."
            
        case NSFileProviderError.providerNotFound:
            recoveryAttempter = nil
            localizedDescription = "Unable to start file provider extension"
            recoverySugestion = "Please ensure you do not have two Proton Drive apps installed at the same time. If this it the case, remove the one outside /Applications folder."
            
        default:
            recoveryAttempter = nil
            localizedDescription = underlyingError.localizedDescription
            recoverySugestion = underlyingError.localizedRecoverySuggestion ?? ""
        }
        
        var errorToPresent = NSError(underlyingError, adding: [
            NSLocalizedDescriptionKey: localizedDescription,
            NSLocalizedRecoverySuggestionErrorKey: recoverySugestion
        ])
        
        if let recoveryAttempter {
            errorToPresent = NSError(errorToPresent, adding: [
                NSLocalizedRecoveryOptionsErrorKey: recoveryAttempter.localizedRecoveryOptions,
                NSRecoveryAttempterErrorKey: recoveryAttempter
            ])
        }
        
        window.presentError(errorToPresent)
        guard recoveryAttempter == nil else { return }
        isTerminatingDueToAppCoordinatorError = true
        NSApp.terminate(nil)
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
