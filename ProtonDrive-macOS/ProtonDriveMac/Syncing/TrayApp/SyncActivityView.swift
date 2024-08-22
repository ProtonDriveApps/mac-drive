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

import SwiftUI
import PDCore
import ProtonCoreUIFoundations

struct SyncActivityView: View {

    @ObservedObject var vm: SyncActivityViewModel

    /// Delays the display to give that to updates to get retrieved
    @State private var shouldShowContent = false

    private let titleBarHeight: CGFloat = 28
    private let wholeViewHeight: CGFloat = 470
    private let headerHeight: CGFloat = 62

    var size: CGSize {
        CGSize(width: 360, height: wholeViewHeight - titleBarHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                initials: vm.initials,
                displayName: vm.displayName,
                emailAddress: vm.emailAddress, 
                syncingPausedSubject: vm.syncingPausedSubject,
                shouldShowAccountActions: (vm.accountInfo != nil),
                actions: vm.headerViewActions
            )
            .frame(height: headerHeight)

            if vm.accountInfo != nil {
                if shouldShowContent {
                    ItemListView(items: $vm.sortedItems, baseURL: vm.itemBaseURL ?? URL(fileURLWithPath: ""))
                        .frame(minHeight: 282, idealHeight: 282, maxHeight: 324)
                }

                if vm.erroredItemsCount > 0 {
                    errorNotificationView()
                } else {
                    #if HAS_BUILTIN_UPDATER
                    switch vm.updateAvailability {
                    case .readyToInstall:
                        updateNotificationView()
                    default:
                        Spacer()
                    }
                    #else
                    Spacer()
                    #endif
                }

                Divider()
                StateView(
                    state: $vm.overallState,
                    syncedTitle: $vm.syncedTitle,
                    action: { vm.changeSyncingStatus() }
                )
                .frame(height: 28)

                ToolbarView(actions: vm.toolbarActions)
                    .frame(height: 56)
            } else {
                if let signInAction = vm.signInAction {
                    VStack {
                        Button {
                            signInAction()
                        } label: {
                            Text("Sign in")
                        }
                        .frame(height: 44)
                        .foregroundStyle(ColorProvider.TextNorm)
                    }
                    .frame(height: wholeViewHeight - headerHeight)
                }
            }
        }
        .background(ColorProvider.BackgroundNorm)
        .ignoresSafeArea()
        .frame(width: size.width, height: size.height)
        .fixedSize()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.shouldShowContent = true
            }
        }
    }

    private func errorNotificationView() -> some View {
        NotificationView(
            state: $vm.notificationState,
            errorsCount: $vm.erroredItemsCount,
            action: vm.actions.showErrorWindow
        )
        .frame(height: 42)
    }

    #if HAS_BUILTIN_UPDATER
    private func updateNotificationView() -> some View {
        NotificationView(
            state: $vm.notificationState,
            errorsCount: $vm.erroredItemsCount,
            action: vm.installUpdate
        )
        .frame(height: 42)
    }
    #endif
}

struct SyncActivityView_Previews: PreviewProvider {
    
    static var sessionVault: SessionVault {
        let keyMaker = DriveKeymaker(autolocker: nil, keychain: DriveKeychain.shared)
        return SessionVault(mainKeyProvider: keyMaker)
    }

    static var storageManager: StorageManager {
        StorageManager(suite: Constants.appGroup, sessionVault: sessionVault)
    }

    static var syncStorageManager: SyncStorageManager {
        SyncStorageManager(suite: Constants.appGroup)
    }

    static var previewModel: SyncActivityViewModel {
        #if HAS_BUILTIN_UPDATER
        SyncActivityViewModel(
            metadataMonitor: nil,
            sessionVault: sessionVault,
            communicationService: nil,
            appUpdateService: SparkleAppUpdateService(),
            syncStateService: SyncStateService(),
            itemBaseURL: URL(string: "www.google.com"),
            signInAction: {}
        )
        #else
        SyncActivityViewModel(
            metadataMonitor: nil,
            sessionVault: sessionVault,
            communicationService: nil,
            itemBaseURL: URL(string: "www.google.com"),
            signInAction: {}
        )
        #endif
    }

    static var viewModelActions: SyncActivityViewModel.Actions {
        #if HAS_QA_FEATURES
        (
            pauseSyncing: {},
            resumeSyncing: {},
            showSettings: {},
            showQASettings: {},
            showLogsInFinder: {},
            reportBug: {},
            showErrorWindow: {},
            openDriveFolder: {},
            viewOnline: {},
            addStorage: {},
            quitApp: {}
        )
        #else
        (
            pauseSyncing: {},
            resumeSyncing: {},
            showSettings: {},
            showLogsInFinder: {},
            reportBug: {},
            showErrorWindow: {},
            openDriveFolder: {},
            viewOnline: {},
            addStorage: {},
            quitApp: {}
        )
        #endif
    }

    static var previews: some View {
        SyncActivityView(vm: previewModel)
            .frame(width: 360, height: 470 + 28) // add titlebar height for Preview
            .background(ignoresSafeAreaEdges: .all)
    }
}
