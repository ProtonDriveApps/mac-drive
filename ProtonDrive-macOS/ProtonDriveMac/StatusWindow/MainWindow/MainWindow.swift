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
    /// The resync variant, which determines the recovery buttons (see `FullResyncButtons.Context`): a
    /// user-initiated resync is pausable and cancellable; a login/domain-reconnection resync is neither and
    /// offers "create a new sync folder" instead. Evaluated at render time, since the trigger can change.
    private let resyncButtonContext: () -> FullResyncButtons.Context

    /// Drives the resync info popover shown by the ⓘ button.
    @State private var isResyncInfoPresented = false

    init(
        state: ApplicationState,
        actions: UserActions,
        resyncButtonContext: @escaping () -> FullResyncButtons.Context = { .userInitiated }
    ) {
        self.state = state
        self.actions = actions
        self.resyncButtonContext = resyncButtonContext
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

                // The resync owns the whole content area (the step list) while running, so hide the
                // notification banner, status row, and footer while it does.
                if !state.fullResyncState.isHappening {
                    notificationView()

                    Divider()

                    SyncStateView(
                        state: state,
                        action: actions.sync.togglePausedStatus
                    )
                    .frame(height: 28)

                    FooterView(state: state, actions: actions)
                        .frame(height: 56)
                }
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
            case .resyncFinished:
                NotificationView(
                    state: state,
                    action: { withAnimation { actions.resync.finishFullResync() } }
                )
                .frame(height: 42)

            case .automaticResyncReason:
                NotificationView(
                    state: state,
                    action: { withAnimation { actions.resync.dismissAutomaticResyncReason() } }
                )
                .frame(height: 42)

            case .volumeLocked:
                NotificationView(
                    state: state,
                    action: { actions.links.openVolumeLockedHelp(email: state.accountInfo?.email) }
                )
                .frame(height: 42)

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
            if state.fullResyncState.isHappening {
                fullResyncView()
            } else {
                if state.isLaunching {
                    statusIllustration(
                        imageName: "launching",
                        title: "Initializing sync",
                        subtitle: "This process may take a few minutes.\nYou can safely minimize or close the window.")
                } else if state.isVolumeLocked, state.throttledItems.isEmpty {
                    statusIllustration(
                        imageName: "paused",
                        title: "Sync is paused")
                } else if state.throttledItems.isEmpty {
                    statusIllustration(
                        imageName: "idle",
                        title: "Your files are up to date",
                        subtitle: "Any updates or new activity on your files will appear here.")
                } else {
                    ItemListView(state: state, actions: actions)
                        .frame(maxHeight: .infinity)
                }

            }
        }
        .frame(maxHeight: .infinity)
    }

    private func statusIllustration(imageName: String, title: String, subtitle: String? = nil) -> some View {
        VStack(spacing: 12) {
            Image(imageName)
            Text(title)
                .font(.custom("SF Pro Display", size: 18).weight(.medium))
                .foregroundStyle(ColorProvider.TextNorm)
            if let subtitle {
                Text(subtitle)
                    .font(.custom("SF Pro Display", size: 11.2).weight(.regular))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ColorProvider.TextWeak)
            }
        }
    }
    
    // MARK: - Full resync (step list)

    @ViewBuilder
    private func fullResyncView() -> some View {
        switch state.fullResyncState {
        case .starting:
            fullResyncPreparing()
        case .inProgress, .enumerating, .errored, .paused:
            fullResyncStepList()
        case .idle, .completed:
            // Not reachable: contentView only renders this while the resync is happening. A completed resync
            // returns to the normal file list with a "resync finished" banner (see notificationState).
            EmptyView()
        }
    }

    /// Prep phase before the scan is cancellable: no step list or Pause/Cancel yet.
    private func fullResyncPreparing() -> some View {
        VStack(spacing: 12) {
            Spacer()
            SpinningProgressView(progress: 0, isIndeterminate: true)
            Text(Localization.full_resync_preparing)
                .font(.custom("SF Pro Display", size: 16).weight(.medium))
                .foregroundStyle(ColorProvider.TextNorm)
            Spacer()
        }
    }

    /// Title (with the About-resync ⓘ) + bordered step list + an error box on failure + the state's action buttons.
    private func fullResyncStepList() -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text(state.resyncIsAutomatic ? Localization.full_resync_auto_title : Localization.full_resync_title)
                        .font(.custom("SF Pro Display", size: 16).weight(.semibold))
                        .foregroundStyle(ColorProvider.TextNorm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    resyncInfoButton()
                }

                resyncStepContainer

                // minLength 0: this spacer exists to push the box down when there is spare room. A floor
                // would only steal height from the buttons in the tightest state (errored + 4 steps).
                Spacer(minLength: 0)

                resyncBottomBox
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            resyncFooter()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Bottom margin lives on the container (not the buttons) so it survives in the states with no buttons
        // (the enumerating ones: applying updates / finishing up) — otherwise the content would sit flush
        // against the window border.
        .padding(.bottom, 12)
    }

    /// The steps in a rounded, bordered container with a divider between each row.
    private var resyncStepContainer: some View {
        VStack(spacing: 0) {
            ForEach(Array(resyncSteps.enumerated()), id: \.element.id) { index, step in
                if index > 0 { Divider() }
                FullResyncStepRowView(step: step)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ColorProvider.BorderWeak, lineWidth: 1)
        )
    }

    /// A failed resync shows a red error box below the steps. Other states show nothing here — the
    /// About-resync ⓘ moved to the title row.
    @ViewBuilder
    private var resyncBottomBox: some View {
        if case .errored(let message) = state.fullResyncState {
            resyncErrorBox(message: message)
        }
    }

    /// Red error box shown below the steps when the resync has failed.
    private func resyncErrorBox(message: String) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.custom("SF Pro Display", size: 11.2).weight(.regular))
                .multilineTextAlignment(.leading)
                .foregroundStyle(ColorProvider.SignalDanger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            IconProvider.exclamationCircleFilled
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundStyle(ColorProvider.SignalDanger)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ColorProvider.SignalDanger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ColorProvider.SignalDanger.opacity(0.2), lineWidth: 1)
        )
    }

    private var resyncSteps: [FullResyncStep] {
        FullResyncStepList.steps(variant: state.fullResyncVariant,
                                 state: state.fullResyncState,
                                 furthestStep: state.furthestResyncStep,
                                 stepDetails: state.resyncStepDetails)
    }

    // MARK: Info popover

    private func resyncInfoButton() -> some View {
        Button {
            isResyncInfoPresented = true
        } label: {
            IconProvider.infoCircle
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundStyle(ColorProvider.TextWeak)
        }
        .buttonStyle(.plain)
        .accessibility(identifier: "MainWindow.FullResyncButton.info")
        .popover(isPresented: $isResyncInfoPresented, arrowEdge: .top) {
            resyncInfoPopover()
        }
    }

    @ViewBuilder
    private func resyncInfoPopover() -> some View {
        switch state.fullResyncState {
        case .paused:
            resyncInfoContent(title: Localization.full_resync_title_paused, body: Localization.full_resync_info_paused_body)
        case .errored:
            resyncInfoContent(title: Localization.full_resync_title_failed, body: Localization.full_resync_info_error_body)
        default:
            resyncInfoContent(title: Localization.full_resync_info_title, body: Localization.full_resync_info_body)
        }
    }

    private func resyncInfoContent(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.custom("SF Pro Display", size: 13).weight(.semibold))
                .foregroundStyle(ColorProvider.TextNorm)
            Text(body)
                .font(.custom("SF Pro Display", size: 11.2).weight(.regular))
                .foregroundStyle(ColorProvider.TextWeak)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
    }

    // MARK: Action buttons

    /// The bottom row: the state's action buttons, or — in the states that offer none (applying updates /
    /// finishing up, which can no longer be paused or cancelled) — a hint that the window can be closed.
    @ViewBuilder
    private func resyncFooter() -> some View {
        let kinds = FullResyncButtons.buttons(for: state.fullResyncState, context: resyncButtonContext())
        if kinds.isEmpty {
            Text(Localization.full_resync_safe_to_leave)
                .font(.custom("SF Pro Display", size: 11.2).weight(.regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(ColorProvider.TextWeak)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .accessibility(identifier: "MainWindow.FullResync.safeToLeaveHint")
        } else {
            resyncButtons(kinds)
        }
    }

    @ViewBuilder
    private func resyncButtons(_ kinds: [FullResyncButtons.Kind]) -> some View {
        if kinds.contains(.createNewLocation) {
            // Login-reconnection recovery: the two options share one row (their titles wrap to two lines)
            // because stacking them full-width does not fit the window.
            HStack(spacing: 12) {
                resyncButton(.createNewLocation)
                resyncButton(.retry)
            }
            .padding(.horizontal, 16)
        } else {
            // Cancel on the left (secondary), the primary action on the right.
            HStack(spacing: 12) {
                if kinds.contains(.cancel) { resyncButton(.cancel) }
                if kinds.contains(.pause) { resyncButton(.pause) }
                if kinds.contains(.resume) { resyncButton(.resume) }
                if kinds.contains(.retry) { resyncButton(.retry) }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Builds one action button. Cancel's action + identifier depend on whether the resync is paused.
    @ViewBuilder
    private func resyncButton(_ kind: FullResyncButtons.Kind) -> some View {
        switch kind {
        case .pause:
            ResyncActionButton(title: Localization.full_resync_pause,
                               icon: IconProvider.pause,
                               style: .primary,
                               action: actions.resync.pauseFullResync)
                .accessibility(identifier: "MainWindow.FullResyncButton.pause")
        case .resume:
            ResyncActionButton(title: Localization.full_resync_resume,
                               icon: IconProvider.play,
                               style: .primary,
                               action: actions.resync.resumeFullResync)
                .accessibility(identifier: "MainWindow.FullResyncButton.resume")
        case .retry:
            ResyncActionButton(title: Localization.general_retry,
                               icon: IconProvider.arrowsRotate,
                               style: .primary,
                               action: actions.resync.retryFullResync)
                .accessibility(identifier: "MainWindow.FullResyncButton.retry")
        case .createNewLocation:
            ResyncActionButton(title: Localization.full_resync_create_new_location,
                               style: .secondary,
                               action: actions.resync.createNewDomainAfterFailedResync)
                .accessibility(identifier: "MainWindow.FullResyncButton.createNewDomain")
        case .cancel:
            if case .paused = state.fullResyncState {
                ResyncActionButton(title: Localization.general_cancel,
                                   icon: IconProvider.crossCircle,
                                   style: .secondary,
                                   action: actions.resync.cancelPausedResync)
                    .accessibility(identifier: "MainWindow.FullResyncButton.cancelPaused")
            } else {
                ResyncActionButton(title: Localization.general_cancel,
                                   icon: IconProvider.crossCircle,
                                   style: .secondary,
                                   action: actions.resync.cancelFullResync)
                    .accessibility(identifier: "MainWindow.FullResyncButton.cancel")
            }
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
        ),

        (
            "Resync · discovering",
            {
                let mock = ApplicationState.mock()
                mock.setFullResyncVariant(.v2)
                mock.fullResyncState = .inProgress(saved: 5_320, total: nil)
                return mock
            }()
        ),

        (
            "Resync · downloading",
            {
                let mock = ApplicationState.mock()
                mock.setFullResyncVariant(.v2)
                mock.fullResyncState = .inProgress(saved: 5_000, total: 6_000)
                return mock
            }()
        ),

        (
            "Resync · errored",
            {
                let mock = ApplicationState.mock()
                mock.setFullResyncVariant(.v2)
                mock.fullResyncState = .errored("The Proton servers are unreachable.")
                return mock
            }()
        ),

        (
            "Resync · finished",
            {
                let mock = ApplicationState.mock()
                mock.setFullResyncVariant(.v2)
                mock.fullResyncState = .completed(hasFileProviderResponded: true, warning: nil)
                return mock
            }()
        )
    ]

    static var previews: some View {
        Group {
            ForEach(mocks, id: \.0) { mock in
                VStack {
                    MainWindow(state: mock.1, actions: UserActions(delegate: nil), resyncButtonContext: { .loginReconnection })
                        .frame(width: 360, height: 470 + 28)
                        .background(ignoresSafeAreaEdges: .all)
                }
            }
        }
    }
}
#endif
