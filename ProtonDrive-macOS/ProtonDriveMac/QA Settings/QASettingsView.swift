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

struct QASettingsView: View {
    @ObservedObject var vm: QASettingsViewModel

    var body: some View {
        ScrollView {
            VStack {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .bottom, spacing: 12) {
                            VStack(alignment: .leading) {
                                Text("Environment")
                                    .font(.system(size: 13))
                                    .fixedSize(horizontal: false, vertical: true)
                                
                                TextField("drive.{scientist}.proton.{tld}", text: $vm.environment)
                                    .font(.system(size: 11))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .onSubmit(vm.confirmEnvironmentChange)
                            }
                            .frame(maxWidth: 350, alignment: .leading)
                            
                            Button {
                                vm.confirmEnvironmentChange()
                            } label: {
                                Text("Sign out & quit")
                                    .padding(.horizontal, 10)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .center, spacing: 8) {
                                Text("Parent session UID")
                                TextField("", text: .constant(vm.parentSessionUID))
                            }
                            HStack(alignment: .center, spacing: 8) {
                                Text("Child session UID")
                                TextField("", text: .constant(vm.childSessionUID))
                            }
                            HStack(alignment: .center, spacing: 8) {
                                Text("User ID")
                                TextField("", text: .constant(vm.userID))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                } label: {
                    Text("BE environment")
                        .font(.headline)
                        .padding(.bottom, 10)
                        .padding(.top, 20)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        if vm.domainDisconnected {
                            Button("Reconnect domain") {
                                vm.sendNotificationToReconnectDomain()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        } else {
                            Button("Disconnect domain") {
                                vm.sendNotificationToDisconnectDomain()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }
                        
                        Button("Clear credentials and crash") {
                            vm.clearCredentials()
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                        VStack {
                            HStack {
                                TextField("Hello!", text: $vm.domainDisconnectionReason)
                                    .font(.system(size: 11))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .onSubmit(vm.confirmDomainDisconnectionReasonChange)
                                
                                Toggle("Temporary?", isOn: $vm.shouldDisconnectTemporarily)
                            }
                            Button("Change reason (disconnecting if needed)") {
                                vm.confirmDomainDisconnectionReasonChange()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                } label: {
                    Text("File Provider Domain")
                        .font(.headline)
                        .padding(.bottom, 10)
                        .padding(.top, 20)
                }
                
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Picker(selection: $vm.disconnectDomainOnSignOut) {
                                ForEach(QASettingsViewModel.FeatureFlagOptions.allCases.map(\.rawValue), id: \.self) {
                                    Text($0)
                                }
                            } label: {
                                Text("Disconnect domain")
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            
                            Text("Backend feature flag value: \(vm.parallelEncryptionAndVerificationFeatureFlagValue ? "true" : "false")")
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Picker(selection: $vm.parallelEncryptionAndVerification) {
                                ForEach(QASettingsViewModel.FeatureFlagOptions.allCases.map(\.rawValue), id: \.self) {
                                    Text($0)
                                }
                            } label: {
                                Text("Parallel encryption and verification")
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            
                            Text("Backend feature flag value: \(vm.parallelEncryptionAndVerificationFeatureFlagValue ? "true" : "false")")
                        }
                    }
                } label: {
                    Text("Feature flags")
                        .font(.headline)
                        .padding(.bottom, 10)
                        .padding(.top, 20)
                }

#if HAS_BUILTIN_UPDATER
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle(isOn: $vm.shouldUpdateEvenOnDebugBuild) {
                            Text("Update even on debug builds")
                            Spacer()
                                .frame(maxWidth: .infinity)
                        }
                        .toggleStyle(SwitchToggleStyle())
                        
                        Toggle(isOn: $vm.shouldUpdateEvenOnTestFlight) {
                            Text("Update even on TestFlight builds")
                            Spacer()
                                .frame(maxWidth: .infinity)
                        }
                        .toggleStyle(SwitchToggleStyle())
                        Picker(selection: $vm.updateChannel) {
                            ForEach(AppUpdateChannel.allCases.map(\.rawValue), id: \.self) {
                                Text($0)
                            }
                        } label: {
                            Text("Select update channel")
                        }
                        .pickerStyle(MenuPickerStyle())
                        
                        Text(vm.updateMessage)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                } label: {
                    Text("Testing auto-update")
                        .font(.headline)
                        .padding(.bottom, 10)
                        .padding(.top, 20)
                }
#endif

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle(isOn: $vm.shouldFetchEvents) {
                            Text("Fetch events from backend (turn off to make testing the refresh easier)")
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Spacer()
                                .frame(maxWidth: .infinity)
                        }
                        .toggleStyle(SwitchToggleStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                } label: {
                    Text("Testing user-initiated refresh")
                        .font(.headline)
                        .padding(.bottom, 10)
                        .padding(.top, 20)
                }
                
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Button("Send test error event to Sentry from macOS app") {
                            vm.sentTestEventToSentry(level: .error)
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Send test info event to Sentry from macOS app") {
                            vm.sentTestEventToSentry(level: .info)
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Crash macOS app to test Sentry crash reporting") {
                            vm.sentTestCrashToSentry()
                        }
                        .buttonStyle(.bordered)
                        
                        Divider()
                        
                        Button("Send test error event to Sentry from file provider") {
                            vm.tellFileProviderToTestSendingErrorEventToTestSentry()
                        }
                        
                        Button("Crash file provider to test Sentry") {
                            vm.tellFileProviderToTestSendingCrashToSentry()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                } label: {
                    Text("Testing Sentry")
                        .font(.headline)
                        .padding(.bottom, 10)
                        .padding(.top, 20)
                }
                
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Button("Wipe main key and kill app") {
                            vm.wipeMainKey()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                } label: {
                    Text("MainKey error testing")
                        .font(.headline)
                        .padding(.bottom, 10)
                        .padding(.top, 20)
                }
                
                GroupBox {
                    VStack {
                        if vm.dumperIsBusy {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .purple))
                        } else {
                            Toggle(isOn: $vm.shouldObfuscateDumps) {
                                Text("Obfuscate node names")
                            }
                            .toggleStyle(SwitchToggleStyle())
                            
                            HStack {
                                Button("Dump DB") {
                                    vm.dumpDBReplica()
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Dump FS") {
                                    vm.dumpFSReplica()
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Dump Cloud") {
                                    vm.dumpCloudReplica()
                                }
                                .buttonStyle(.bordered)
                            }
                            
                            if !vm.dumperError.isEmpty {
                                Text(vm.dumperError)
                                    .font(.footnote)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                } label: {
                    Text("FileSystem & CoreData & Cloud sync")
                        .font(.headline)
                        .padding(.bottom, 10)
                        .padding(.top, 20)
                }
            }
            .frame(width: 350)
            .padding(20)
        }
        .frame(minHeight: 600)
    }
}

#endif
