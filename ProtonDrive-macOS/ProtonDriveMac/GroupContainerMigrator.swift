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
import ProtonCoreFeatureFlags
import os.log

protocol GroupContainerMigratorProtocol {
    var hasGroupContainerMigrationHappened: Bool { get }
    
    func migrateUserDefaults()

    @MainActor
    func migrateDatabasesForLoggedInUser(domainOperationsService: DomainOperationsServiceProtocol,
                                         featureFlags: FeatureFlagsRepositoryProtocol,
                                         logoutClosure: () -> Void) async
    
    @MainActor
    func migrateDatabasesBeforeLogin(featureFlags: FeatureFlagsRepositoryProtocol) async
}

final class GroupContainerMigrator: GroupContainerMigratorProtocol {
    
    @SettingsStorage("userDefaultsMigrationHappened") private var userDefaultsMigrationHappened: Bool?
    @SettingsStorage("databaseMigrationHappened") private var databaseMigrationHappened: Bool?
    
    private var windowsForErrors: [NSWindow] = []
    private let fileManager: GroupContainerFileOperationsProvider
    private let logger: Logger
    private var delayedEvents: [(LogLevel, String, Bool)] = []
    private var permissionPopupWasShown = false
    var hasGroupContainerMigrationHappened: Bool = false
    
    static let instance = GroupContainerMigrator()
    
    init(fileManager: GroupContainerFileOperationsProvider = FileManager.default) {
        self.fileManager = fileManager
        self.logger = Logger(subsystem: "ch.protonmail.drive", category: LogDomain.application.name)
    }
    
    func checkIfMigrationIsNessesary() {
        guard appIsRunForTheFirstTimeEver() else {
            appendToDelayedEvents(.info, "GroupContainerMigration: the app has been run before, this is not the first time", false)
            return
        }
        // No need to migrate anything if the app is run for the first time ever
        userDefaultsMigrationHappened = true
        databaseMigrationHappened = true
        appendToDelayedEvents(.info, "GroupContainerMigration: the app is running for the first time ever", false)
    }
 
    func migrateUserDefaults() {
        // there is no kill switch here, because the feture flags are stored in the user defaults,
        // so we must migrate their storage before we can check them.
        // also, the loggers are not available at this point, so we just log to console
        
        guard userDefaultsMigrationHappened != true else {
            appendToDelayedEvents(.info, "GroupContainerMigration: user defaults migration already happened or never needed", false)
            return
        }
        
        if #available(macOS 15.0, *) {
            presentPopupAskingForAccessToOldContainer()
        }
        do {
            try moveAllValuesFromOldUserDefaultsToNewUserDefaults()
        } catch {
            presentPopupInformingAboutAppBeingUnableToWork()
        }
    }
    
    private func appIsRunForTheFirstTimeEver() -> Bool {
        // this relies on these folders being created at the previous app start
        let cleartextCacheDirectoryPath = FileManager.default.temporaryDirectory.appendingPathComponent("Clear").path(percentEncoded: false)
        let cypherBlocksPermanentDirectoryPath = Constants.appGroup.directoryUrl.appendingPathComponent("Downloads").path(percentEncoded: false)
        
        let appWasAlreadyRun = FileManager.default.fileExists(atPath: cleartextCacheDirectoryPath)
        || FileManager.default.fileExists(atPath: cypherBlocksPermanentDirectoryPath)
        return !appWasAlreadyRun
    }
    
    private func moveAllValuesFromOldUserDefaultsToNewUserDefaults() throws {
        guard let fromUserDefaults = UserDefaults(suiteName: Constants.legacyOldNoLongerUsedAppContainerGroup),
              let toUserDefaults = UserDefaults(suiteName: Constants.appContainerGroup)
        else {
            assertionFailure("The user defaults should always be available")
            throw GroupContainerMigratorError.userDefaultsUnavailable
        }
        
        guard let fromDictionary = fromUserDefaults.persistentDomain(forName: Constants.legacyOldNoLongerUsedAppContainerGroup) else {
            appendToDelayedEvents(.error, "GroupContainerMigration: old user defaults are empty", true)
            throw GroupContainerMigratorError.userDefaultsUnavailable
        }
        
        toUserDefaults.setPersistentDomain(fromDictionary, forName: Constants.appContainerGroup)
        fromUserDefaults.removePersistentDomain(forName: Constants.legacyOldNoLongerUsedAppContainerGroup)
        
        userDefaultsMigrationHappened = true
        appendToDelayedEvents(.info, "GroupContainerMigration: user defaults migration succeeded", true)
    }
    
    @MainActor
    func migrateDatabasesForLoggedInUser(domainOperationsService: DomainOperationsServiceProtocol,
                                         featureFlags: FeatureFlagsRepositoryProtocol,
                                         logoutClosure: () -> Void) async {
        do {
            hasGroupContainerMigrationHappened = try await migrateDatabases(domainOperationsService, featureFlags)
        } catch {
            hasGroupContainerMigrationHappened = false
            let nsError = error as NSError
            Log.error("GroupContainerMigration: migration failed due to \(nsError.localizedDescription), \(nsError.code), \(nsError.userInfo)",
                      domain: .application)
            presentPopupInformingAboutDomainRemovalForLoggedInUser()
            do {
                try await handleContainerMigrationError(error, domainOperationsService, logoutClosure)
            } catch {
                Log.error("GroupContainerMigration: domain removal and logout failed", domain: .application)
                fatalError("GroupContainerMigration: domain removal and logout failed")
            }
        }
    }
    
    @MainActor
    func migrateDatabasesBeforeLogin(featureFlags: FeatureFlagsRepositoryProtocol) async {
        do {
            hasGroupContainerMigrationHappened = try await migrateDatabases(nil, featureFlags)
        } catch {
            hasGroupContainerMigrationHappened = false
            let nsError = error as NSError
            Log.error("GroupContainerMigration: migration failed due to \(nsError.localizedDescription), \(nsError.code), \(nsError.userInfo)",
                      domain: .application)
            presentPopupInformingAboutDomainRemovalBeforeLogin()
        }
    }
    
    @MainActor
    func presentDatabaseMigrationPopup() async {
        if #available(macOS 15.0, *) {
            presentPopupAllowingForAppRestart()
        }
    }
    
    @MainActor
    private func migrateDatabases(_ domainOperationsService: DomainOperationsServiceProtocol?,
                                  _ featureFlags: FeatureFlagsRepositoryProtocol) async throws -> Bool {
        // here we log and send to sentry the events that happened before the logger was available
        logDelayedEvents()
        
        guard databaseMigrationHappened != true else {
            Log.info("GroupContainerMigration: container migration already happened or never needed", domain: .application)
            return false
        }
        
        let killSwitchEnabled = featureFlags.isEnabled(
            GroupContainerMigratorFeatureFlag.driveMacGroupContainerMigrationDisabled, reloadValue: true
        )
        guard !killSwitchEnabled else {
            Log.info("GroupContainerMigration: container migration killswitch enabled", domain: .application)
            return false
        }
        
        if let domainOperationsService {
            // The error here do not stop the migration, because it's an additional safety guard
            // against a race condition in which the file provider extension performs any operation
            // on the database in the new location while migration is in progress. Error indicates
            // the file provider is not available at the moment, so we should be good to proceed.
            try? await domainOperationsService.groupContainerMigrationStarted()
        }
        
        if #available(macOS 15.0, *) {
            presentPopupAskingForAccessToOldContainer()
        }
        
        guard let oldContainer = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Constants.legacyOldNoLongerUsedAppContainerGroup),
              let newContainer = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Constants.appContainerGroup)
        else {
            throw GroupContainerMigratorError.containersUnavailable
        }
        
        // exclude from copying:
        // * Library folder, because it contains the user defaults (that are migrated separately)
        // * containermanagerd metadata, because it's not a file we control
        let itemsToCopy = try fileManager.contentsOfDirectory(at: oldContainer)
            .filter { $0.lastPathComponent != "Library" }
            .filter { $0.lastPathComponent != ".com.apple.containermanagerd.metadata.plist" }
        guard !itemsToCopy.isEmpty else {
            // if there's nothing to be copied, let's just exit early
            databaseMigrationHappened = true
            Log.info("GroupContainerMigration: no need to migrate container", domain: .application, sendToSentryIfPossible: true)
            return true
        }
        
        try itemsToCopy.forEach { fromURL in
            let toURL = newContainer.appending(path: fromURL.lastPathComponent, directoryHint: .checkFileSystem)
            // we prevent losing logs, we move the logs during migration to a separate directory
            if fromURL.lastPathComponent == "Logs" {
                let newToURL = toURL.deletingLastPathComponent().appending(path: "LogsFromContainerMigration", directoryHint: .isDirectory)
                try? fileManager.moveItem(at: toURL, to: newToURL)
            }
            do {
                try fileManager.moveItem(at: fromURL, to: toURL)
            } catch {
                let nsError = error as NSError
                guard nsError.domain == NSCocoaErrorDomain,
                      CocoaError.Code(rawValue: nsError.code) == .fileWriteFileExists
                else { throw error }
                do {
                    _ = try fileManager.replaceItemAt(toURL, with: fromURL)
                } catch {
                    // the last try
                    try fileManager.removeItem(at: toURL)
                    try fileManager.moveItem(at: fromURL, to: toURL)
                }
            }
        }
        
        databaseMigrationHappened = true
        Log.info("GroupContainerMigration: container migration succeeded", domain: .application, sendToSentryIfPossible: true)
        
        // sanity check, ignore error here
        do {
            let uncopiedItems = try fileManager.contentsOfDirectory(at: oldContainer)
                .filter { $0.lastPathComponent != "Library" }
                .filter { $0.lastPathComponent != ".com.apple.containermanagerd.metadata.plist" }
            if !uncopiedItems.isEmpty {
                Log.error("GroupContainerMigration: some items left at the old container: \(uncopiedItems)", domain: .application)
                assertionFailure("GroupContainerMigration: some items left at the old container")
            }
        } catch {}
        
        return true
    }
    
    private func appendToDelayedEvents(_ level: OSLogType, _ message: String, _ sendToSentry: Bool) {
        logger.log(level: level, "\(message). Date: (\(Date())")
        let logLevel: LogLevel
        switch level {
        case .debug: logLevel = .debug
        case .info: logLevel = .info
        case .error: logLevel = .error
        case .fault: logLevel = .error
        default: logLevel = .warning
        }
        delayedEvents.append((logLevel, message, sendToSentry))
    }
    
    private func logDelayedEvents() {
        let domain: LogDomain = .application
        delayedEvents.forEach { level, message, sendToSentry in
            switch level {
            case .info: Log.info(message, domain: domain, sendToSentryIfPossible: sendToSentry)
            case .warning: Log.warning(message, domain: domain, sendToSentryIfPossible: sendToSentry)
            case .debug: Log.debug(message, domain: domain, sendToSentryIfPossible: sendToSentry)
            case .error: Log.info(message, domain: domain, sendToSentryIfPossible: sendToSentry)
            }
        }
        delayedEvents.removeAll()
    }
    
    private func createWindow() -> NSWindow {
        let window = NSWindow()
        window.makeKeyAndOrderFront(nil)
        window.close()
        windowsForErrors.append(window)
        return window
    }
    
    private func presentPopupAskingForAccessToOldContainer() {
        guard !permissionPopupWasShown else { return }
        
        let localizedDescription = "Migration required"
        let recoverySugestion = "Proton Drive must perform a one-off data migration to make it compatible with macOS 15 Sequoia. This requires access to a filesystem location used in previous versions of macOS. Please allow temporary wider access in the following system popup."
        
        let errorToPresent = NSError(domain: "ch.protonmail.drive", code: 0, userInfo: [
            NSLocalizedDescriptionKey: localizedDescription,
            NSLocalizedRecoverySuggestionErrorKey: recoverySugestion
        ])
        
        permissionPopupWasShown = true
        
        createWindow().presentError(errorToPresent)
    }
    
    private func presentPopupInformingAboutAppBeingUnableToWork() {
        let localizedDescription = "Migration failed"
        let recoverySugestion = "The migration is required for the app to work. Please restart the app to try again."

        let recoveryAttempter = makeRestartingRecoveryAttempter()
        recoveryAttempter.option(with: "Quit app without restarting") { _ in exit(0) }
        
        let errorToPresent = NSError(domain: "ch.protonmail.drive", code: 0, userInfo: [
            NSLocalizedDescriptionKey: localizedDescription,
            NSLocalizedRecoverySuggestionErrorKey: recoverySugestion,
            NSLocalizedRecoveryOptionsErrorKey: recoveryAttempter.localizedRecoveryOptions,
            NSRecoveryAttempterErrorKey: recoveryAttempter
        ])
        
        createWindow().presentError(errorToPresent)
    }
    
    @MainActor
    private func presentPopupAllowingForAppRestart() {
        let localizedDescription = "Migration successful!"
        let recoverySugestion = "Proton Drive will now restart and remove access to the wider filesystem."
        
        let recoveryAttempter = makeRestartingRecoveryAttempter()
        
        let errorToPresent = NSError(domain: "ch.protonmail.drive", code: 0, userInfo: [
            NSLocalizedDescriptionKey: localizedDescription,
            NSLocalizedRecoverySuggestionErrorKey: recoverySugestion,
            NSLocalizedRecoveryOptionsErrorKey: recoveryAttempter.localizedRecoveryOptions,
            NSRecoveryAttempterErrorKey: recoveryAttempter
        ])
        
        createWindow().presentError(errorToPresent)
    }
    
    private func makeRestartingRecoveryAttempter() -> RecoveryAttempter {
        let recoveryAttempter = RecoveryAttempter()
        recoveryAttempter.option(with: "Restart the app now") { error in
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", "sleep \(1); open \"\(Bundle.main.bundlePath)\""]
            task.launch()
            exit(0)
        }
        
        return recoveryAttempter
    }
    
    @MainActor
    private func presentPopupInformingAboutDomainRemovalForLoggedInUser() {
        let localizedDescription = "Migration failed"
        let recoverySugestion = "The migration required by changes in macOS 15 Sequoia has failed. Please log back in."
        
        let errorToPresent = NSError(domain: "ch.protonmail.drive", code: 0, userInfo: [
            NSLocalizedDescriptionKey: localizedDescription,
            NSLocalizedRecoverySuggestionErrorKey: recoverySugestion
        ])
        
        createWindow().presentError(errorToPresent)
    }
    
    @MainActor
    private func presentPopupInformingAboutDomainRemovalBeforeLogin() {
        let localizedDescription = "Migration failed"
        let recoverySugestion = "The migration required by changes in macOS 15 Sequoia has failed."
        
        let errorToPresent = NSError(domain: "ch.protonmail.drive", code: 0, userInfo: [
            NSLocalizedDescriptionKey: localizedDescription,
            NSLocalizedRecoverySuggestionErrorKey: recoverySugestion
        ])
        
        createWindow().presentError(errorToPresent)
    }
    
    private func handleContainerMigrationError(
        _ error: Error, _ domainOperationsService: DomainOperationsServiceProtocol, _ logout: () -> Void = { /* no-op */ }
    ) async throws {
        try await domainOperationsService.removeAllDomains()
        logout()
    }
}

// MARK: - Helper objects

private enum GroupContainerMigratorFeatureFlag: String, FeatureFlagTypeProtocol {
    case driveMacGroupContainerMigrationDisabled = "DriveMacGroupContainerMigrationDisabled"
}

private enum GroupContainerMigratorError: String, LocalizedError {
    case userDefaultsUnavailable = "User defaults are unavailable"
    case containersUnavailable = "Fetching the app group containers urls has failed"
    
    var errorDescription: String? { rawValue }
}

protocol GroupContainerFileOperationsProvider {
    func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL?
    func contentsOfDirectory(at url: URL) throws -> [URL]
    
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func removeItem(at URL: URL) throws
    func replaceItemAt(_ originalItemURL: URL, with newItemURL: URL) throws -> URL?
}

extension FileManager: GroupContainerFileOperationsProvider {
    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
    
    func replaceItemAt(_ originalItemURL: URL, with newItemURL: URL) throws -> URL? {
        try replaceItemAt(originalItemURL, withItemAt: newItemURL, backupItemName: nil, options: [])
    }
}
