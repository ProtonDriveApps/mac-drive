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

#if !HAS_BUILTIN_UPDATER

/// When not using Sparkle we exclude all updater-related code during compilation,
/// but we still need a protocol for use in method signatures, where we would have passed in an updater if we had one.
protocol AppUpdateServiceProtocol: AnyObject {}

#else

import AppKit
import Combine
import PDCore
import Sparkle

protocol AppUpdateServiceProtocol: AnyObject {
    var updater: SPUUpdater { get }
    var updateAvailability: UpdateAvailabilityStatus { get }
    var updateAvailabilityPublisher: AnyPublisher<UpdateAvailabilityStatus, Never> { get }
    func installUpdateIfAvailable()
    func checkForUpdates()
}

enum UpdateAvailabilityStatus: Equatable {
    case upToDate(version: String)
    case checking
    case downloading(version: String)
    case extracting(version: String)
    case readyToInstall(version: String)
    case errored(userFacingMessage: String)
}

enum AppUpdateChannel: String, CaseIterable {
    case stable
    case beta
    case alpha
    #if HAS_QA_FEATURES
    // special channels for testing variou update scenarios
    case testNoUpdate = "test-no-update"
    case testUpdateAvailable = "test-update-available"
    case testInvalidUpdate = "test-invalid"
    case testKeyRotation = "test-key-rotation"
    #endif
}

final class SparkleAppUpdateService: NSObject, AppUpdateServiceProtocol, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    
    @Published private(set) var updateAvailability: UpdateAvailabilityStatus
    var updateAvailabilityPublisher: AnyPublisher<UpdateAvailabilityStatus, Never> {
        self.$updateAvailability.eraseToAnyPublisher()
    }
    
    private static let shortUpdateCheckInterval: TimeInterval = 60 * 60 // one hour, minumum possible in Spark
    private static let longUpdateCheckInterval: TimeInterval = 24 * 60 * 60 // one day
    
    #if HAS_QA_FEATURES
    @SettingsStorage(QASettingsConstants.shouldUpdateEvenOnDebugBuild) private var shouldUpdateEvenOnDebugBuild: Bool?
    @SettingsStorage(QASettingsConstants.shouldUpdateEvenOnTestFlight) private var shouldUpdateEvenOnTestFlight: Bool?
    @SettingsStorage(QASettingsConstants.updateChannel) private var updateChannel: String?
    #endif
    
    private var debugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    
    private var buildFromTestFlight: Bool {
        // Based on Sentry's implementation of the same check
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }
    
    private var isUpdateMechanismOn: Bool {
        #if HAS_QA_FEATURES
        let shouldUpdateEvenOnTestFlight = self.shouldUpdateEvenOnTestFlight ?? false
        let shouldUpdateEvenOnDebugBuild = self.shouldUpdateEvenOnDebugBuild ?? false
        #else
        let shouldUpdateEvenOnTestFlight = false
        let shouldUpdateEvenOnDebugBuild = false
        #endif
        // The update mechanism is automatically on for all builds unless:
        // * it's a debug build, to not interfere with the development environment
        // * it's a TestFlight build, to not interfere with the TestFlight updater
        return (!buildFromTestFlight || shouldUpdateEvenOnTestFlight)
            && (!debugBuild || shouldUpdateEvenOnDebugBuild)
    }
    
    private var installUpdateImmediately: (() -> Void)?
    
    #if HAS_QA_FEATURES
    // properties made available in QA builds to allow showing updater state in QA settings screen
    var updater: SPUUpdater { updaterController.updater }
    var updaterController: SPUStandardUpdaterController!
    #else
    var updater: SPUUpdater { updaterController.updater }
    private var updaterController: SPUStandardUpdaterController!
    #endif
    
    init(updaterController: SPUStandardUpdaterController? = nil) {
        self.updateAvailability = .upToDate(version: Constants.versionDigits)
        super.init()
        if let updaterController {
            self.updaterController = updaterController
        } else {
            self.updaterController = .init(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        }
        self.checkForUpdates()
    }
    
    func checkForUpdates() {
        
        setUpdateInterval(to: SparkleAppUpdateService.longUpdateCheckInterval)
        
        guard isUpdateMechanismOn else { return }
        
        do {
            try updater.start()
            if updater.canCheckForUpdates {
                updater.checkForUpdatesInBackground()
            }
        } catch {
            updateAvailability = .errored(userFacingMessage: error.localizedDescription)
        }
    }
    
    func installUpdateIfAvailable() {
        guard case .readyToInstall(let version) = updateAvailability,
                let installUpdateImmediately else { return }
        Log.info("User initiated update to \(version), app will be restarted now", domain: .updater)
        installUpdateImmediately()
    }
    
    private func setUpdateInterval(to interval: TimeInterval) {
        updater.automaticallyChecksForUpdates = isUpdateMechanismOn
        updater.automaticallyDownloadsUpdates = isUpdateMechanismOn
        if isUpdateMechanismOn {
            updater.updateCheckInterval = interval
        } else {
            updater.updateCheckInterval = .infinity
        }
    }
}

// configuration
extension SparkleAppUpdateService {

    var supportsGentleScheduledUpdateReminders: Bool {
        return true
    }
    
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        #if HAS_QA_FEATURES
        updateChannel.map { [$0] } ?? []
        #else
        // we only allow the stable channel in non-QA builds
        [AppUpdateChannel.stable.rawValue]
        #endif
    }
    
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        return true
    }
    
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        return false
    }
    
    func updater(_ updater: SPUUpdater,
                 shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        return false
    }
}

// state machine
extension SparkleAppUpdateService {
    private func setServiceStateToChecking() {
        installUpdateImmediately = nil
        updateAvailability = .checking
    }
    
    private func setServiceStateToUpToDate() {
        installUpdateImmediately = nil
        updateAvailability = .upToDate(version: Constants.versionDigits)
        setUpdateInterval(to: SparkleAppUpdateService.longUpdateCheckInterval)
    }
    
    private func setStateToDownloading(item: SUAppcastItem) {
        installUpdateImmediately = nil
        updateAvailability = .downloading(version: item.displayVersionString)
    }
    
    private func setStateToExtracting(item: SUAppcastItem) {
        installUpdateImmediately = nil
        updateAvailability = .extracting(version: item.displayVersionString)
    }
    
    private func handleUserIndependentErrorWithShorterRetry(error: Error) {
        // error is not user-facing
        logErrorIfNeeded(error) { $0.localizedDescription }
        installUpdateImmediately = nil
        // since we don't show it to the user, we just set `upToDate`
        updateAvailability = .upToDate(version: Constants.versionDigits)
        // error could be gone next time, so schedule a quicker check
        setUpdateInterval(to: SparkleAppUpdateService.shortUpdateCheckInterval)
    }
    
    private func handleUserFacingErrorWithShorterRetry(error: Error) {
        installUpdateImmediately = nil
        updateAvailability = .errored(userFacingMessage: error.localizedDescription)
        setUpdateInterval(to: SparkleAppUpdateService.shortUpdateCheckInterval)
    }
    
    private func handleUserIndependentErrorWithLongerRetry(error: Error) {
        // error is not user-facing
        logErrorIfNeeded(error) { $0.localizedDescription }
        installUpdateImmediately = nil
        // since we don't show it to the user, we just set `upToDate`
        updateAvailability = .upToDate(version: Constants.versionDigits)
        setUpdateInterval(to: SparkleAppUpdateService.longUpdateCheckInterval)
    }
    
    private func setStateToReadyToInstall(immediateInstallHandler: @escaping () -> Void,
                                          item: SUAppcastItem) {
        installUpdateImmediately = immediateInstallHandler
        updateAvailability = .readyToInstall(version: item.displayVersionString)
    }
}

// updater callbacks causing state machine transitions
extension SparkleAppUpdateService {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        setServiceStateToChecking()
    }
    
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        setServiceStateToChecking()
    }
    
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain,
              let reasonValue = nsError.userInfo[SPUNoUpdateFoundReasonKey] as? OSStatus,
              let reason = SPUNoUpdateFoundReason(rawValue: reasonValue)
        else {
            setServiceStateToUpToDate()
            return
        }
        
        switch reason {
        case .onLatestVersion, .onNewerThanLatestVersion, .systemIsTooNew, .systemIsTooOld:
            setServiceStateToUpToDate()
        case .unknown:
            handleUserIndependentErrorWithShorterRetry(error: error)
        @unknown default:
            handleUserIndependentErrorWithShorterRetry(error: error)
        }
    }
    
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain,
              let errorCode = SUError(rawValue: OSStatus(nsError.code))
        else {
            setServiceStateToUpToDate()
            return
        }
        
        switch errorCode {
        
        // Configuration phase errors.
        case .noPublicDSAFoundError,
             .insufficientSigningError,
             .insecureFeedURLError,
             .invalidFeedURLError,
             .invalidUpdaterError,
             .invalidHostBundleIdentifierError,
             .invalidHostVersionError:
            handleUserIndependentErrorWithLongerRetry(error: nsError)
            
        // Appcast phase errors.
        case .appcastParseError,
             .appcastError,
             .resumeAppcastError,
             .webKitTerminationError,
             .releaseNotesError:
            handleUserIndependentErrorWithLongerRetry(error: nsError)
        case .runningTranslocated,
             .runningFromDiskImageError:
            handleUserFacingErrorWithShorterRetry(error: nsError)
        case .noUpdateError:
            setServiceStateToUpToDate()
            
        // Download phase errors.
        case .temporaryDirectoryError:
            handleUserFacingErrorWithShorterRetry(error: nsError)
            
        case .downloadError:
            handleUserFacingErrorWithShorterRetry(error: nsError)

        // Extraction phase errors.
        case .unarchivingError,
             .signatureError,
             .validationError:
            handleUserIndependentErrorWithLongerRetry(error: nsError)
            
        // Installation phase errors.
        case .authenticationFailure,
             .missingUpdateError,
             .missingInstallerToolError,
             .agentInvalidationError,
             .installationError:
            handleUserIndependentErrorWithLongerRetry(error: nsError)
        case .fileCopyFailure,
             .downgradeError,
             .relaunchError,
             .installationAuthorizeLaterError,
             .installationRootInteractiveError,
             .installationWriteNoPermissionError:
            handleUserFacingErrorWithShorterRetry(error: nsError)
        case .installationCanceledError:
            handleUserIndependentErrorWithLongerRetry(error: nsError)
        case .notValidUpdateError:
            setServiceStateToUpToDate()
            
        // API misuse errors.
        case .incorrectAPIUsageError:
            handleUserIndependentErrorWithLongerRetry(error: nsError)

        @unknown default:
            handleUserIndependentErrorWithLongerRetry(error: nsError)
        }
    }
    
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setServiceStateToChecking()
    }
    
    func updater(_ updater: SPUUpdater,
                 willDownloadUpdate item: SUAppcastItem,
                 with request: NSMutableURLRequest) {
        setStateToDownloading(item: item)
    }
    
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        setStateToDownloading(item: item)
    }
    
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        setStateToExtracting(item: item)
    }
    
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        setStateToExtracting(item: item)
    }
    
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        setStateToReadyToInstall(immediateInstallHandler: immediateInstallHandler, item: item)
        return true
    }
}

// updater callbacks that should be logged for error reporting / debugging
extension SparkleAppUpdateService {
    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        Log.info(#function, domain: .updater)
    }
        
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Log.info("Next update cycle scheduled in \(delay)", domain: .updater)
    }
    
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            logErrorIfNeeded(error) { "Update cycle \(updateCheck) finished with error \($0)" }
        } else {
            Log.info("Update cycle \(updateCheck) finished successfully", domain: .updater)
        }
    }
    
    private func logErrorIfNeeded(_ error: Error, _ errorMessage: (Error) -> String) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain {
            if nsError.code == SUError.noUpdateError.rawValue,
               let reason = nsError.userInfo[SPUNoUpdateFoundReasonKey] as? SPUNoUpdateFoundReason.RawValue,
               reason == SPUNoUpdateFoundReason.onLatestVersion.rawValue || reason == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue {
                // do not log if using latest or newer version, it only adds noise
                return
            } else if nsError.code == SUError.downloadError.rawValue {
                // do not log if it's just a network failure
                return
            }
        }
        Log.error(errorMessage(error), domain: .updater)
    }
}
#endif
