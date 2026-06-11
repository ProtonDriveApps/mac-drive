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

#if HAS_QA_FEATURES

import SwiftUI
import PDCore

struct RuntimeConfigurationSettingsView: View {
    @State private var includeTracesInLogs: Bool
    @State private var includeChangeEnumerationSummaryInTrayApp: Bool
    @State private var includeChangeEnumerationDetailsInTrayApp: Bool
    @State private var includeItemEnumerationSummaryInTrayApp: Bool
    @State private var includeItemEnumerationDetailsInTrayApp: Bool
    @State private var eventLoopInterval: String
    @State private var enableTestAutomation: Bool
    @State private var systemMetricsMonitoringInterval: String
    @State private var includedLogDomainNames: String
    @State private var excludedLogDomainNames: String

    @State private var saveResult: String = ""

    private static let allDomainNames = Log.domains

    init() {
        let config = RuntimeConfiguration.shared
        _includeTracesInLogs = State(initialValue: config.includeTracesInLogs)
        _includeChangeEnumerationSummaryInTrayApp = State(initialValue: config.includeChangeEnumerationSummaryInTrayApp)
        _includeChangeEnumerationDetailsInTrayApp = State(initialValue: config.includeChangeEnumerationDetailsInTrayApp)
        _includeItemEnumerationSummaryInTrayApp = State(initialValue: config.includeItemEnumerationSummaryInTrayApp)
        _includeItemEnumerationDetailsInTrayApp = State(initialValue: config.includeItemEnumerationDetailsInTrayApp)
        _eventLoopInterval = State(initialValue: String(config.eventLoopInterval))
        _enableTestAutomation = State(initialValue: config.enableTestAutomation)
        _systemMetricsMonitoringInterval = State(initialValue: String(config.systemMetricsMonitoringInterval))
        _includedLogDomainNames = State(initialValue: config.includedLogDomainNames.joined(separator: ", "))
        _excludedLogDomainNames = State(initialValue: config.excludedLogDomainNames.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            toggleRow("Include traces in logs", isOn: $includeTracesInLogs)
                            toggleRow("Include change enumeration summary in tray app", isOn: $includeChangeEnumerationSummaryInTrayApp)
                            toggleRow("Include change enumeration details in tray app", isOn: $includeChangeEnumerationDetailsInTrayApp)
                            toggleRow("Include item enumeration summary in tray app", isOn: $includeItemEnumerationSummaryInTrayApp)
                            toggleRow("Include item enumeration details in tray app", isOn: $includeItemEnumerationDetailsInTrayApp)
                            toggleRow("Enable test automation", isOn: $enableTestAutomation)
                        }
                        .padding(16)
                    } label: {
                        Text("Boolean settings")
                            .font(.headline)
                            .padding(.bottom, 10)
                            .padding(.top, 20)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Event loop interval (seconds)")
                                .font(.system(size: 13))
                            TextField("90.0", text: $eventLoopInterval)
                                .font(.system(size: 11))

                            Text("System metrics monitoring interval (seconds, 0 = disabled)")
                                .font(.system(size: 13))
                            TextField("0", text: $systemMetricsMonitoringInterval)
                                .font(.system(size: 11))
                        }
                        .padding(16)
                    } label: {
                        Text("Numeric settings")
                            .font(.headline)
                            .padding(.bottom, 10)
                            .padding(.top, 20)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Included log domain names (comma-separated)")
                                    .font(.system(size: 13))
                                TextField("syncing, enumerating, ...", text: $includedLogDomainNames)
                                    .font(.system(size: 11))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Excluded log domain names (comma-separated)")
                                    .font(.system(size: 13))
                                TextField("clientNetworking, ...", text: $excludedLogDomainNames)
                                    .font(.system(size: 11))
                            }

                            DisclosureGroup("Available domain names") {
                                Text(Self.allDomainNames.map { $0.name }.joined(separator: ", "))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 4)
                            }
                            .font(.system(size: 12))
                        }
                        .padding(16)
                    } label: {
                        Text("Log domains")
                            .font(.headline)
                            .padding(.bottom, 10)
                            .padding(.top, 20)
                    }
                }
                .frame(width: 350)
                .padding(20)
            }

            HStack {
                Button("Save & Restart") {
                    saveAndRestart()
                }
                .buttonStyle(.borderedProminent)

                Button("Save") {
                    save()
                }
                .buttonStyle(.bordered)

                if !saveResult.isEmpty {
                    Text(saveResult)
                        .font(.system(size: 11))
                        .foregroundColor(saveResult.starts(with: "Error") ? .red : .green)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .frame(minHeight: 600)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(SwitchToggleStyle())
    }

    private func buildSettings() -> [String: Any] {
        let included = includedLogDomainNames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let excluded = excludedLogDomainNames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return [
            "includeTracesInLogs": includeTracesInLogs,
            "includeChangeEnumerationSummaryInTrayApp": includeChangeEnumerationSummaryInTrayApp,
            "includeChangeEnumerationDetailsInTrayApp": includeChangeEnumerationDetailsInTrayApp,
            "includeItemEnumerationSummaryInTrayApp": includeItemEnumerationSummaryInTrayApp,
            "includeItemEnumerationDetailsInTrayApp": includeItemEnumerationDetailsInTrayApp,
            "eventLoopInterval": Double(eventLoopInterval) ?? RuntimeConfiguration.shared.eventLoopInterval,
            "enableTestAutomation": enableTestAutomation,
            "systemMetricsMonitoringInterval": UInt(systemMetricsMonitoringInterval) ?? RuntimeConfiguration.shared.systemMetricsMonitoringInterval,
            "includedLogDomainNames": included,
            "excludedLogDomainNames": excluded,
        ]
    }

    private func save() {
        do {
            try RuntimeConfiguration.shared.save(settings: buildSettings())
            saveResult = "Saved. Restart app to apply."
        } catch {
            saveResult = "Error: \(error.localizedDescription)"
        }
    }

    private func saveAndRestart() {
        do {
            try RuntimeConfiguration.shared.save(settings: buildSettings())
            UserActions(delegate: nil).app.restartApp()
        } catch {
            saveResult = "Error: \(error.localizedDescription)"
        }
    }
}

#endif
