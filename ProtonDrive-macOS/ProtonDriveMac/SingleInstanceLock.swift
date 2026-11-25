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
import PDCore

/// A mechanism for preventing multiple instances of the app from running simultaneously.
protocol SingleInstanceLocking {
    /// Attempts to acquire an exclusive instance lock.
    /// - Returns: `true` if this process now holds the lock (first instance),
    ///            `false` if another process already holds it (second instance).
    ///            Also returns `true` on any filesystem error (fail-open).
    func acquireLock() -> Bool

    /// Blocks until this process holds the exclusive instance lock.
    /// - Returns: `true` once this process holds the lock,
    ///            `false` if the lock file can't be opened or locked. Unlike `acquireLock()`, it doesn't fail open.
    func waitForLock() -> Bool
}

/// Uses POSIX `flock(2)` to ensure only one instance of the app runs at a time.
///
/// The lock is held for the lifetime of the file descriptor, which should be stored
/// in a static property to survive until process exit. The kernel automatically releases
/// the lock when the process terminates — including SIGKILL, crash, or normal exit.
final class FlockInstanceLock: SingleInstanceLocking {

    private static let logFileName = "log-ProtonDriveMac.instance_lock.log"
    private let logFileURL: URL
    private let lockFileURL: URL
    /// Retains the file descriptor for the process lifetime.
    /// -1 means no lock is held.
    private var fileDescriptor: Int32 = -1

    /// Creates a lock targeting a specific file URL. Used in tests with temp files.
    /// - Parameters:
    ///   - lockFileURL: Path for the POSIX lock file.
    ///   - logFileURL: Path for the diagnostic log file. Defaults to the same directory as the lock file.
    ///                 Pass a separate URL in tests when the lock directory may not exist.
    init(lockFileURL: URL, logFileURL: URL? = nil) {
        self.lockFileURL = lockFileURL
        self.logFileURL = logFileURL ?? lockFileURL.deletingLastPathComponent().appendingPathComponent(Self.logFileName)
    }

    /// Creates a lock in the app group container.
    /// On macOS, `containerURL(forSecurityApplicationGroupIdentifier:)` always returns a URL
    /// even for invalid groups. The real validation happens in `acquireLock()` — if the path
    /// is unusable, `open()` fails and we fail-open.
    convenience init(containerGroupIdentifier: String) {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: containerGroupIdentifier
        ) ?? FileManager.default.temporaryDirectory
        self.init(lockFileURL: containerURL.appendingPathComponent(".instance.lock"))
    }

    func acquireLock() -> Bool {
        guard fileDescriptor == -1 else {
            writeLog("Lock already held by this process — skipping redundant acquire")
            return true
        }

        let path = lockFileURL.path

        // O_WRONLY: minimum permission that reliably supports exclusive flock (some FS require write).
        // O_CREAT: creates the file on first launch; no-op when it already exists from a previous run.
        // 0o600: owner-only read/write — no other user needs access to this private lock token.
        // Returns a non-negative fd on success, -1 on failure.
        let fd = open(path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else {
            writeLog("fail-open: can't determine if another instance is running. open() failed for \(path) — errno \(errno) (\(errnoDescription)).")
            return true
        }

        // LOCK_EX: exclusive — only one holder at a time (mutual exclusion between app instances).
        // LOCK_NB: non-blocking — returns immediately with EWOULDBLOCK instead of waiting forever.
        // Returns 0 on success, -1 on failure.
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            fileDescriptor = fd // retain fd so the lock is held for the process lifetime
            return true
        }

        // Snapshot errno before close() can overwrite it.
        let flockErrno = errno
        close(fd)

        // EWOULDBLOCK is the only definitive signal that another process holds the lock.
        // Every other error (EINTR, EIO, ENOLCK) is ambiguous, so we fail-open.
        if flockErrno == EWOULDBLOCK {
            return false
        }

        writeLog("fail-open: can't determine if another instance is running. flock() failed with unexpected errno \(flockErrno) (\(errnoDescription(for: flockErrno))).")
        return true
    }

    func waitForLock() -> Bool {
        guard fileDescriptor == -1 else {
            return true
        }

        let fd = open(lockFileURL.path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else {
            let openErrno = errno
            writeLog("Can't wait for the lock: open() failed with errno \(openErrno) (\(errnoDescription(for: openErrno))).")
            return false
        }

        // Without LOCK_NB, flock() sleeps until the holder releases the lock, which the kernel does when it exits.
        var result: Int32
        repeat {
            result = flock(fd, LOCK_EX)
        } while result != 0 && errno == EINTR

        guard result == 0 else {
            let flockErrno = errno
            close(fd)
            writeLog("Can't wait for the lock: flock() failed with errno \(flockErrno) (\(errnoDescription(for: flockErrno))).")
            return false
        }

        fileDescriptor = fd
        return true
    }

    deinit {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }
    
    // MARK: - Logging

    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private var errnoDescription: String {
        errnoDescription(for: errno)
    }

    private func errnoDescription(for code: Int32) -> String {
        String(cString: strerror(code))
    }

    /// Maximum number of log lines retained in the log file.
    /// Older entries beyond this limit are discarded on the next write.
    private static let maxLogLines = 20

    private func writeLog(_ message: String) {
        let timestamp = Self.logDateFormatter.string(from: Date())
        let newLine = "\(timestamp) \(message)"

        var existingLines: [String] = []
        if let contents = try? String(contentsOf: logFileURL, encoding: .utf8) {
            existingLines = contents.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.isEmpty }
        }

        existingLines.append(newLine)

        // Keep only the most recent entries.
        if existingLines.count > Self.maxLogLines {
            existingLines = Array(existingLines.suffix(Self.maxLogLines))
        }

        let output = existingLines.joined(separator: "\n") + "\n"
        try? output.data(using: .utf8)?.write(to: logFileURL, options: .atomic)
    }
}

/// Called from `main.m` before `NSApplicationMain`, so a second copy of the app never creates an `NSApplication`:
/// macOS runs TCC preflight checks for every `NSApplication` created.
@objc(SingleInstanceGate)
final class SingleInstanceGate: NSObject {

    /// Passed by `ch.protonmail.drive.agent.plist` to the copy that launchd starts for the relaunch agent.
    static let relaunchAgentArgument = "--relaunch-agent"

    /// Holds the lock for the entire process lifetime.
    /// The kernel releases the lock automatically on process exit (including SIGKILL).
    private static let instanceLock: SingleInstanceLocking = FlockInstanceLock(
        containerGroupIdentifier: Constants.appContainerGroup
    )

    enum Decision {
        case launch
        case exitAsDuplicate
        case exitToRetry
    }

    static func decide(arguments: [String], lock: SingleInstanceLocking) -> Decision {
        if arguments.contains(relaunchAgentArgument) {
            return lock.waitForLock() ? .launch : .exitToRetry
        }
        return lock.acquireLock() ? .launch : .exitAsDuplicate
    }

    @objc static func ensureSingleInstance() {
        switch decide(arguments: CommandLine.arguments, lock: instanceLock) {
        case .launch:
            return
        case .exitAsDuplicate:
            assert(false, "Exiting because another instance is already running.")
            exit(0)
        case .exitToRetry:
            // launchd restarts the relaunch agent's copy after a non-zero exit (KeepAlive.SuccessfulExit is false).
            exit(1)
        }
    }
}
