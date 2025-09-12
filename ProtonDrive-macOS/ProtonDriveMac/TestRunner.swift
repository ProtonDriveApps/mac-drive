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

import ApplicationServices
import PDCore
import AppKit

enum TestRunnerAction {
    case logIn(String, String)
    case logOut
    case startApp
    case stopApp
    case beginTest(String)
    case endTest(String)
    case pauseSyncing
    case resumeSyncing
    case resetErrors
    case keepDownloaded(String)
    case keepOnlineOnly(String)
    case startFullResync
    case finishFullResync
    case dumpDiagnostics(String)
    case openMenu
    case takeScreenshot(String)
    case log(String)

    private static let commandPrefix = "protondrive://testrunner/"

    init?(eventURL: String) {
        let eventRawString = String(eventURL.trimmingPrefix(Self.commandPrefix))
        switch eventRawString {
        case "start":
            self = .startApp
        case "stop":
            self = .stopApp
        case let message where message.hasPrefix("login/"):
            // Format: "login:john@example.com/password:123" or "login:john/password:123"
            if let loginStart = eventRawString.range(of: "login/login:")?.upperBound,
               let passwordStart = eventRawString.range(of: "/password:")?.lowerBound {
                let email = String(eventRawString[loginStart..<passwordStart])
                let password = String(eventRawString[passwordStart...].dropFirst("/password:".count))
                self = .logIn(email, password)
            } else {
                return nil
            }
        case "logout":
            self = .logOut
        case let message where message.hasPrefix("begin_test/"):
            self = .beginTest(String(message.dropFirst(11)))
        case let message where message.hasPrefix("end_test/"):
            self = .endTest(String(message.dropFirst(9)))
        case "pause":
            self = .pauseSyncing
        case "resume":
            self = .resumeSyncing
        case "reset_errors":
            self = .resetErrors
        case let message where message.hasPrefix("keep_downloaded/"):
            self = .keepDownloaded(String(message.dropFirst(16)))
        case let message where message.hasPrefix("keep_online_only/"):
            self = .keepOnlineOnly(String(message.dropFirst(17)))
        case "full_resync_start":
            self = .startFullResync
        case "full_resync_finish":
            self = .finishFullResync
        case let message where message.hasPrefix("diagnostics/"):
            self = .dumpDiagnostics(String(message.dropFirst(12)))
        case "open_menu":
            self = .openMenu
        case let message where message.hasPrefix("take_screenshot/"):
            self = .takeScreenshot(String(message.dropFirst(16)))
        case let message where message.hasPrefix("log/"):
            self = .log(String(message.dropFirst(4)))
        default:
            return nil
        }
    }

    /// Optionally returns a string that will be sent back to the application which made the call
    func run(_ userActions: UserActions, _ testRunner: TestRunner) async -> String? {
        switch self {
        case .startApp:
            // nothing to do
            break
        case .stopApp:
            fatalError("App stopped by TestRunner")

        case .logIn(let login, let password):
            userActions.account.signInUsingTestCredentials(login: login, password: password)
        case .logOut:
            userActions.account.userRequestedSignOut()

        case .beginTest(let testRunId):
            testRunner.beginTest(testRunId: testRunId)
        case .endTest(let diagnostics):
            // Disable dumping all data until it can be done more efficiently (DM-851)
            // await testRunner.dump(diagnostics: diagnostics)
            testRunner.endTest()
        case .dumpDiagnostics(let diagnostics):
            await testRunner.dump(diagnostics: diagnostics)

        case .pauseSyncing:
            userActions.sync.pauseSyncing()
        case .resumeSyncing:
            userActions.sync.resumeSyncing()

        case .resetErrors:
            userActions.sync.cleanUpErrors()

        case .keepDownloaded(let paths):
            userActions.fileProvider.keepDownloaded(paths: paths.components(separatedBy: ":"))
        case .keepOnlineOnly(let paths):
            userActions.fileProvider.keepOnlineOnly(paths: paths.components(separatedBy: ":"))

        case .startFullResync:
            userActions.resync.performFullResync()

        case .finishFullResync:
            userActions.resync.finishFullResync()

        case .openMenu:
            userActions.app.toggleStatusWindow(onlyOpen: true)

        case .takeScreenshot(let filename):
            testRunner.takeScreenshot(filename: filename)

        case .log(let message):
            Log.debug(message, domain: .testRunner)
        }
        return nil
    }
}

enum DiagnosticDumpType {
    case filesystem
    case database
    case cloud
}

/// Listens and reacts to events sent from the test runner.
class TestRunner {
    private let appCoordinator: AppCoordinator
    private let userActions: UserActions
    private var testRunId: String?

    init(coordinator: AppCoordinator) {
        self.appCoordinator = coordinator
        self.userActions = UserActions(delegate: coordinator)
        self.listenToAppleEvents()
    }

    private func listenToAppleEvents() {
        NSAppleEventManager.shared().setEventHandler(self,
                                                     andSelector: #selector(handleGetURLEvent(event:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @MainActor
    @objc func handleGetURLEvent(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
            reportError("Missing urlString", reply: reply)
            return
        }

        guard let action = TestRunnerAction(eventURL: urlString) else {
            reportError("Unrecognized action: \(urlString)", reply: reply)
            return
        }

        Log.trace("\(action)")

        /// This is necessary because this method is synchronous, and `reply` has to be modified before it exits -
        /// but action.run() has to be asynchronous because otherwise we still wouldn't be able to wait until the action is completed.
        let semaphore = DispatchSemaphore(value: 0)

        var resultString: String?
        Task.detached {
            resultString = await action.run(self.userActions, self)
            semaphore.signal()
        }

        semaphore.wait()

        if let resultString {
            let responseDescriptor = NSAppleEventDescriptor(string: resultString)
            reply.setParam(responseDescriptor, forKeyword: keyDirectObject)
        }
    }

    /// If an error has occurred, the response will be prefixed with "Error: "
    private func reportError(_ message: String, reply: NSAppleEventDescriptor) {
        Log.warning("handleGetURLEvent error: \(message)", domain: .testRunner)
        let errorDescriptor = NSAppleEventDescriptor(string: "Error: \(message)")
        reply.setParam(errorDescriptor, forKeyword: keyDirectObject)
    }

    fileprivate func beginTest(testRunId: String) {
        Log.trace()
        self.testRunId = testRunId
        writeTestRunId(testRunId)
        Log.configureAppForTesting(testRunId: testRunId)
        Log.info("Began logging test run \(testRunId)", domain: .testRunner)
    }

    fileprivate func endTest() {
        Log.info("Will stop logging test run \(testRunId ?? "n/a")", domain: .testRunner)
        testRunId = nil
        deleteTestRunIdFile()
        Log.configureAppForTesting(testRunId: nil)
    }

    fileprivate func dump(diagnostics diagnosticsString: String) async {
        var diagnostics = Set<DiagnosticDumpType>()
        if diagnosticsString.contains("filesystem") { diagnostics.insert(.filesystem) }
        if diagnosticsString.contains("database") { diagnostics.insert(.database) }
        if diagnosticsString.contains("cloud") { diagnostics.insert(.cloud) }

        if !diagnostics.isEmpty {
            do {
                try await dumpDiagnostics(diagnostics)
            } catch {
                Log.error("Could not dump diagnostics \(diagnosticsString)", domain: .testRunner)
            }
        }
    }

    private func dumpDiagnostics(_ diagnostics: Set<DiagnosticDumpType>) async throws {
        Log.trace()

        guard let tower = appCoordinator.tower else {
            return
        }
        let dumperDependencies = DumperDependencies(
            tower: tower,
            domainOperationsService: appCoordinator.domainOperationsService
        )
        let dumper = Dumper(dependencies: dumperDependencies)

        if diagnostics.contains(.filesystem) {
            try await dumper.dumpFSReplica()
        }
        if diagnostics.contains(.database) {
            try await dumper.dumpDBReplica()
        }
        if diagnostics.contains(.cloud) {
            try await dumper.dumpCloudReplica()
        }
    }

    fileprivate func takeScreenshot(filename: String) {
        Log.trace()
        func captureWindow(window: NSWindow, to fileURL: URL) {
            Log.trace()
            guard let contentView = window.contentView else {
                Log.error("Window has no content view", domain: .testRunner)
                return
            }

            let bounds = contentView.bounds
            let imageRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)

            if let imageRep {
                contentView.cacheDisplay(in: bounds, to: imageRep)

                if let pngData = imageRep.representation(using: .png, properties: [:]) {
                    do {
                        try pngData.write(to: fileURL)
                        Log.debug("Saved screenshot to \(fileURL.path)", domain: .testRunner)
                    } catch {
                        Log.error("Failed to save screenshot", error: error, domain: .testRunner)
                    }
                }
            }
        }

        if let window = NSApplication.shared.windows.first {
            let fileURL = testLogDirectory.appendingPathComponent("\(filename)_icon.png")
            captureWindow(window: window, to: fileURL)
        }

        if let window = NSApplication.shared.windows.last {
            let fileURL = testLogDirectory.appendingPathComponent("\(filename)_window.png")
            captureWindow(window: window, to: fileURL)
        }
    }

    func writeSyncStateProperties(_ state: ApplicationState) {
        guard testRunId != nil else {
            return
        }

        let propertiesFilePath = testLogDirectory.appendingPathComponent("sync_state_properties.txt")

        let properties = state.properties + [ApplicationState.Property("timestamp", Log.formattedTime)]
        let data = properties.reduce(into: [:], {
            $0[$1.name] = $1.value
        })

        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            Log.error("Could not encode state properties", domain: .testRunner)
            return
        }

        do {
            try append(jsonString + "\n,\n", to: propertiesFilePath)
        } catch {
            Log.error(error: error, domain: .testRunner)
        }
    }

    func writeSyncStateItems(_ items: [ReportableSyncItem]) {
        guard testRunId != nil else {
            return
        }

        let sanitizedTimestamp = Log.formattedTime
            .replacingOccurrences(of: "[ .]", with: "_", options: .regularExpression)
            .replacingOccurrences(of: "[:]", with: "-", options: .regularExpression)
        let itemsFilePath = testLogDirectory.appendingPathComponent("sync_state_items_\(sanitizedTimestamp).txt")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let jsonData = try? encoder.encode(items),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            Log.error("Could not encode sync state items", domain: .testRunner)
            return
        }

        do {
            try append(jsonString + "\n", to: itemsFilePath)
        } catch {
            Log.error(error: error, domain: .testRunner)
        }
    }

    private func append(_ text: String, to fileUrl: URL) throws {
        let data = Data(text.utf8)

        do {
            let handle = try FileHandle(forUpdating: fileUrl)
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            try handle.write(contentsOf: data)
        } catch CocoaError.fileNoSuchFile {
            try data.write(to: fileUrl)
        } catch {
            throw error
        }
    }

    private func writeTestRunId(_ testRunId: String) {
        // swiftlint:disable force_try
        try! testRunId.write(to: Log.testRunIdFileURL, atomically: true, encoding: .utf8)
        // swiftlint:enable force_try
    }

    private func deleteTestRunIdFile() {
        do {
            try FileManager.default.removeItem(at: Log.testRunIdFileURL)
        } catch {
            Log.error("Failed to delete \(Log.testRunIdFileURL.absoluteString)", error: error, domain: .testRunner)
        }
    }

    /// Test-specific log directory.
    private var testLogDirectory: URL {
        guard let testRunId else {
            fatalError("No test in progress")
        }
        return PDFileManager.logsDirectory.appendingPathComponent(testRunId)
    }

    deinit {
        Log.trace("Deleting \(Log.testRunIdFileURL.absoluteString)")
        try? FileManager.default.removeItem(at: Log.testRunIdFileURL)
    }
}
