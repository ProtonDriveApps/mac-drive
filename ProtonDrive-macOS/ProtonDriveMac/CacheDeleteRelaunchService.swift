// Copyright (c) 2026 Proton AG
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
import ServiceManagement
import PDCore
import AppKit

// This file implements the recommended solution for app being terminated in the background
// by com.apple.cache_delete for CacheDeleteAppContainerCache.
// The recommended solutions was provided at https://developer.apple.com/forums/thread/780456
// The CacheDeleteAppContainerCache mechanism can be forced by CoreServices' CSDiskSpaceStartRecovery function.

protocol RegistrableAgent {
    func register() throws
    func unregister() throws
}

protocol AppRelaunching {
    func scheduleRelaunch()
}

protocol TimestampProvider {
    func currentTimestamp() -> TimeInterval
}

/// Provides the current time so that it's controllable in test.
struct SystemTimestampProvider: TimestampProvider {
    func currentTimestamp() -> TimeInterval {
        // Using timeval() and ProcessInfo.processInfo.systemUptime makes the timestamp user clock setting.
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boottime, &size, nil, 0) == 0 else {
            return Date().timeIntervalSince1970
        }
        let bootTimestamp = TimeInterval(boottime.tv_sec) + TimeInterval(boottime.tv_usec) / 1_000_000
        return bootTimestamp + ProcessInfo.processInfo.systemUptime
    }
}

/// Wrapper for SMAppService so that it's controllable in test.
struct SystemRelaunchAgentService: RegistrableAgent {
    private let service: SMAppService

    init(plistName: String) {
        // The plist defines a launchd agent that relaunches the app after it's closed.
        self.service = SMAppService.agent(plistName: plistName)
    }

    /// Registers a launchd agent so that the system relaunches the app after abnormal termination.
    /// Calling this causes the new instance app to be launched, but we exit it right away in AppDelegate.init().
    func register() throws {
        try service.register()
    }

    /// Unregisters the launchd agent, preventing the system from relaunching the app.
    /// Note that calling this terminates the app, unless called from the `applicationShouldTerminate` method.
    func unregister() throws {
        try service.unregister()
    }
}

struct SystemAppRelauncher: AppRelaunching {
    /// Restarts the app by spawning the separate Process that opens the app after 1s.
    func scheduleRelaunch() {
        scheduleAppRelaunch(afterDelay: 1)
    }
}

/// Manages the launchd relaunch agent that restarts the app after silent background
/// termination by `com.apple.cache_delete` (CacheDeleteAppContainerCache).
///
/// On each launch it registers a launchd agent so the system relaunches the app if it
/// is killed. On clean quit it unregisters the agent so launchd does not restart the app.
/// If two abnormal launches happen within the cooldown window (crash loop), it unregisters
/// the agent to break the loop, persists a flag, and schedules a self-relaunch. The next
/// launch sees the flag, skips registration, and clears the flag.
///
/// A remote kill-switch (`DriveMacAbnormalExitRelaunchDisabled`) can disable the whole
/// mechanism by unregistering the agent after the coordinator starts.
final class CacheDeleteRelaunchService {

    private static let plistName = "ch.protonmail.drive.agent.plist"
    private static let defaultMinimumAbnormalLaunchInterval: TimeInterval = 5 * 60

    @SettingsStorage("lastExitWasClean") private var lastExitWasClean: Bool?
    @SettingsStorage("lastAbnormalLaunchTimestamp") private var lastAbnormalLaunchTimestamp: TimeInterval?
    @SettingsStorage("crashLoopUnregisterPending") private var crashLoopUnregisterPending: Bool?

    private let agentService: RegistrableAgent
    private let appRelauncher: AppRelaunching
    private let timestampProvider: TimestampProvider
    private let minimumAbnormalLaunchInterval: TimeInterval
    private(set) var isRegistered = false

    init(agentService: RegistrableAgent = SystemRelaunchAgentService(plistName: plistName),
         appRelauncher: AppRelaunching = SystemAppRelauncher(),
         suite: SettingsStorageSuite = Constants.appGroup,
         timestampProvider: TimestampProvider = SystemTimestampProvider(),
         minimumAbnormalLaunchInterval: TimeInterval = defaultMinimumAbnormalLaunchInterval) {
        self.agentService = agentService
        self.appRelauncher = appRelauncher
        self.timestampProvider = timestampProvider
        self.minimumAbnormalLaunchInterval = minimumAbnormalLaunchInterval
        self._lastExitWasClean.configure(with: suite)
        self._lastAbnormalLaunchTimestamp.configure(with: suite)
        self._crashLoopUnregisterPending.configure(with: suite)
    }

    /// Called from `applicationDidFinishLaunching`.
    func appDidLaunch() {
        #if DEBUG
        Log.info("Relaunch agent disabled in debug builds", domain: .application)
        #else
        try? registerIfNeeded()
        #endif
    }

    /// Called after the coordinator starts with the value of `DriveMacAbnormalExitRelaunchDisabled`.
    /// When the kill-switch is enabled, clears state, schedules a relaunch, and unregisters the
    /// agent — effectively disabling the whole relaunch mechanism.
    func honourTheKillSwitch(_ isKillSwitchEnabled: Bool) {
        guard isKillSwitchEnabled else { return }
        lastAbnormalLaunchTimestamp = nil
        guard isRegistered else { return }
        try? unregister()
    }

    /// If a previous crash-loop left the `crashLoopUnregisterPending` flag set,
    /// clears it and skips registration. Then checks whether the app
    /// is crash-looping. If it is, persists a pending flag,
    /// schedules a self-relaunch, and unregisters the agent to break the loop.
    /// Otherwise marks the exit as dirty and registers the agent.
    /// Internal (not private) so unit tests can call it directly in DEBUG builds.
    func registerIfNeeded() throws {
        if crashLoopUnregisterPending == true {
            Log.info("Previous crash loop unregister pending — skipping registration", domain: .application)
            crashLoopUnregisterPending = nil
            return
        }
        guard !isCrashLooping() else {
            Log.error("Abnormal relaunch within cooldown, not registering relaunch agent", domain: .application)
            lastAbnormalLaunchTimestamp = nil
            // Persist that we're about to unregister due to crash loop.
            // Calling SMAppService.unregister() terminates the process.
            // It's relaunched after 1 second. After relaunch,
            // appDidLaunch() checks this flag and skips registration.
            crashLoopUnregisterPending = true
            appRelauncher.scheduleRelaunch()
            try? unregister()
            return
        }

        // Mark as not clean — will be set to true on intentional quit
        lastExitWasClean = false

        try register()
    }

    /// Called from `applicationShouldTerminate`. Marks the exit as clean, clears the
    /// abnormal-launch timestamp, and unregisters the agent so launchd does not restart the app after a non-crash termination.
    func appWillTerminate() {
        lastExitWasClean = true
        lastAbnormalLaunchTimestamp = nil
        try? unregister()
    }

    private func register() throws {
        do {
            try agentService.register()
            isRegistered = true
            Log.info("Registered relaunch agent", domain: .application)
        } catch {
            let errorCode = (error as NSError).code
            switch errorCode {
            case kSMErrorAlreadyRegistered:
                isRegistered = true
                Log.info("Relaunch service registration not needed, already registered", domain: .application)
                return
            case kSMErrorLaunchDeniedByUser:
                Log.error("Relaunch service denied by the user", domain: .application)
            case kSMErrorInvalidSignature:
                Log.error("Relaunch service failure, invalid signature", domain: .application)
            default:
                Log.error("Failed to register relaunch agent: \(error)", domain: .application)
            }
            throw error
        }
    }

    private func unregister() throws {
        do {
            try agentService.unregister()
            isRegistered = false
            Log.info("Unregistered relaunch agent", domain: .application)
        } catch {
            let errorCode = (error as NSError).code
            if errorCode == kSMErrorJobNotFound {
                isRegistered = false
                Log.info("Relaunch service unregistration not needed, already unregistered", domain: .application)
                return
            } else {
                Log.error("Failed to unregister relaunch agent: \(error)", domain: .application)
                throw error
            }
        }
    }

    private func isCrashLooping() -> Bool {
        let wasClean = lastExitWasClean ?? true

        if wasClean {
            Log.info("Last exit was clean, last abnormal launch timestamp cleared", domain: .application)
            lastAbnormalLaunchTimestamp = nil
            return false
        }

        let now = timestampProvider.currentTimestamp()

        if let lastTimestamp = lastAbnormalLaunchTimestamp,
           (now - lastTimestamp) < minimumAbnormalLaunchInterval {
            Log.warning("Crash loop detected. Abnormal relaunch within cooldown period (\(now - lastTimestamp)s since last)", domain: .application)
            return true
        }

        Log.warning("Abnormal launch detected, recording timestamp. Previous: \(lastAbnormalLaunchTimestamp.map(\.description) ?? "nil"). Current: \(now)", domain: .application)
        lastAbnormalLaunchTimestamp = now
        return false
    }
}
