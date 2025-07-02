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
import PDLogin_macOS
import PDLocalization

/// Root view of the status menu app
struct MainWindow: View {

    @ObservedObject private(set) var state: ApplicationState
    private var actions: UserActions

    init(
        state: ApplicationState,
        actions: UserActions
    ) {
        self.state = state
        self.actions = actions
    }

    private static let titleBarHeight: CGFloat = 28
    private static let wholeViewHeight: CGFloat = 470
    private static let headerHeight: CGFloat = 62

    static var size: CGSize {
        CGSize(width: 360, height: wholeViewHeight - titleBarHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                state: state,
                actions: actions
            )
            .frame(height: Self.headerHeight)
            
            if state.isLoggedIn || state.fullResyncState.isHappening {
                contentView()
                
                notificationView()
                
                Divider()
                
                SyncStateView(
                    state: state,
                    action: actions.sync.togglePausedStatus
                )
                .frame(height: 28)
                
                FooterView(state: state, actions: actions)
                    .frame(height: 56)
            } else {
                loggedOutView()
            }
#if HAS_QA_FEATURES && DEBUGGING
            debuggingButtons()
#endif
        }
        .background(ColorProvider.BackgroundNorm)
        .ignoresSafeArea()
        .frame(width: Self.size.width, height: Self.size.height)
        .fixedSize()

    }

    private func notificationView() -> some View {
        VStack {
            switch state.notificationState {
            case .error:
                NotificationView(
                    state: state,
                    action: { actions.windows.showErrorWindow() }
                )
                .frame(height: 42)
            case .update:
#if HAS_BUILTIN_UPDATER
                NotificationView(
                    state: state,
                    action: { actions.app.installUpdate() }
                )
                .frame(height: 42)
#else
                EmptyView()
#endif
            case .none:
                EmptyView()
            }
        }
    }

    private func loggedOutView() -> some View {
        VStack(spacing: 20) {
            Image("login_logo", bundle: PDLoginMacOS.bundle)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 175, height: 45)

            LoginButton(
                title: "Sign in",
                isLoading: .constant(false),
                action: actions.windows.showLogin)
                .padding([.bottom], 80)
                .accessibility(identifier: "LoginView.LoginButton.signIn")
        }
        .frame(width: 258, height: Self.wholeViewHeight - Self.headerHeight)
    }

    private func contentView() -> some View {
        VStack(spacing: 10) {
            switch state.fullResyncState {
            case .idle:
                if state.isLaunching {
                    statusIllustration(
                        imageName: "launching",
                        title: "Initializing sync",
                        subtitle: "This process may take a few minutes.\nYou can safely minimize or close the window.")
                } else if state.throttledItems.isEmpty {
                    statusIllustration(
                        imageName: "idle",
                        title: "Your files are up to date",
                        subtitle: "Any updates or new activity on your files will appear here.")
                } else {
                    ItemListView(state: state, actions: actions)
                        .frame(maxHeight: .infinity)
                }

            case .inProgress(let count):
                fullResyncInProgress(count)
            case .completed(let hasFileProviderResponded):
                fullResyncCompleted(hasFileProviderResponded: hasFileProviderResponded)
            case .errored(let errorMessage):
                fullResyncErrored(errorMessage)
            }
            
        }
        .frame(maxHeight: .infinity)
    }

    private func statusIllustration(imageName: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(imageName)
            Text(title)
                .font(.custom("SF Pro Display", size: 18).weight(.medium))
                .foregroundStyle(ColorProvider.TextNorm)
            Text(subtitle)
                .font(.custom("SF Pro Display", size: 11.2).weight(.regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(ColorProvider.TextWeak)
        }
    }
    
    private func fullResyncInProgress(_ count: Int) -> some View {
        VStack(spacing: 10) {
            statusIllustration(imageName: "launching",
                               title: "Resyncing in progress",
                               subtitle: "This process may take a few minutes.")

            Text(Localization.full_resync_progress(itemsProcessed: count))
                .font(.custom("SF Pro Display", size: 14).weight(.medium))
                .foregroundStyle(ColorProvider.TextNorm)
                .padding(.vertical, 8)
            
            LoginButton(title: "Cancel",
                        isLoading: .constant(false),
                        action: actions.sync.cancelFullResync)
                .padding(.horizontal, 32)
                .accessibility(identifier: "MainWindow.FullResyncButton.cancel")
        }
    }
    
    private func fullResyncCompleted(hasFileProviderResponded: Bool) -> some View {
        VStack(spacing: 10) {

            statusIllustration(imageName: "launching",
                               title: "Resync completed",
                               subtitle: "Some changes might take a while to show up in Finder but they have been synced.")

            LoginButton(title: "Continue",
                        isLoading: .constant(false),
                        action: actions.sync.finishFullResync)
                .padding(.horizontal, 32)
                .accessibility(identifier: "MainWindow.FullResyncButton.continue")
        }
    }
    
    private func fullResyncErrored(_ errorMessage: String) -> some View {
        VStack(spacing: 10) {
            statusIllustration(imageName: "launching",
                               title: "Full resync failed",
                               subtitle: errorMessage)
            .padding(.horizontal, 32)
            
            LoginButton(title: "Retry",
                        isLoading: .constant(false),
                        action: actions.sync.retryFullResync)
                .padding(.horizontal, 32)
                .accessibility(identifier: "MainWindow.FullResyncButton.retry")
            
            LoginButton(title: "Cancel",
                        isLoading: .constant(false),
                        action: actions.sync.abortFullResync)
                .padding(.horizontal, 32)
                .accessibility(identifier: "MainWindow.FullResyncButton.cancel")
        }
    }

#if HAS_QA_FEATURES
    private func debuggingButtons() -> some View {
        HStack {
            Button(action: {
                if state.isLoggedIn {
                    actions.mocks?.mockLogout()
                } else {
                    actions.mocks?.mockLogin()
                }
            }, label: {
                Image(systemName: "person")
            })

            Button(action: {
                actions.sync.togglePausedStatus()
            }, label: {
                Image(systemName: "playpause")
            })

            Button(action: {
                actions.mocks?.mockErrorState()
            }, label: {
                Image(systemName: "xmark.square")
            })

            Button(action: {
                actions.mocks?.mockOfflineStatus(offline: !state.isOffline)
            }, label: {
                Image(systemName: "icloud.slash")
            })

#if HAS_BUILTIN_UPDATER
            Button(action: {
                actions.mocks?.mockUpdateAvailability(available: !state.isUpdateAvailable)
            }, label: {
                Image(systemName: "arrow.down.square")
            })
#endif
        }
    }
#endif
}

#if HAS_QA_FEATURES
struct MainWindowView_Previews: PreviewProvider {
    static var mocks: [(String, ApplicationState)] = [

        ("Logged out", ApplicationState.mock(loggedIn: false)),

        (
            "Idle",
            {
                let mock = ApplicationState.mock()
                return mock
            }()
        ),

        (
            "Paused",
            {
                let mock = ApplicationState.mock(isPaused: true, items: ApplicationState.mockItems)
                return mock
            }()
        ),

        (
            "Error + pause",
            {
                let mock = ApplicationState.mock(isPaused: true, items: ApplicationState.mockItems)
                return mock
            }()
        ),

        (
            "Offline",
            {
                let mock = ApplicationState.mock(isOffline: true)
                return mock
            }()
        ),

        (
            "Launching",
            {
                let mock = ApplicationState.mock(isLaunching: true)
                return mock
            }()
        )
    ]

    static var previews: some View {
        Group {
            ForEach(mocks, id: \.0) { mock in
                VStack {
                    MainWindow(state: mock.1, actions: UserActions(delegate: nil))
                        .frame(width: 360, height: 470 + 28)
                        .background(ignoresSafeAreaEdges: .all)
                }
            }
        }
    }
}
#endif
