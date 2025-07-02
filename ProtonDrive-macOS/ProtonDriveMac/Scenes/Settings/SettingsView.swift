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

import SwiftUI
import PDUIComponents
import ProtonCoreUIFoundations
import PDLocalization
import PDCore

struct SettingsView<ViewModel: SettingsViewModelProtocol>: View {

    let minimalSize = CGSize(width: 500.0, height: 500)
    let idealSize = CGSize(width: 680.0, height: 860)
    let maxSize = CGSize(width: 800, height: 900)

    private var viewModel: ViewModel

    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionView(headline: Localization.setting_account) {
                    SettingsAccountSection(viewModel: viewModel)
                }

                SettingsSectionView(headline: Localization.setting_storage) {
                    SettingsStorageSection(viewModel: viewModel)
                }
                
                SettingsSectionView(headline: Localization.setting_system) {
                    SettingsSystemSection(viewModel: viewModel)
                }
                
                if viewModel.isFullResyncEnabled {
                    HideableView(modifier: .option, defaultView: {
                        EmptyView()
                    }, pressedView: {
                        SettingsSectionView(headline: Localization.setting_fix_syncing_issues) {
                            SettingsFullResyncSection(viewModel: viewModel)
                        }
                    })
                }

                SettingsSectionView(headline: Localization.setting_get_help) {
                    SettingsGetHelpSection(viewModel: viewModel)
                }

                SettingsFooterView(viewModel: viewModel)
            }
            .padding([.leading, .trailing], 100)
            .padding(.bottom, 32)
        }
        .tint(ColorProvider.LinkNorm)
        .frame(minWidth: minimalSize.width, idealWidth: idealSize.width, maxWidth: maxSize.width,
               minHeight: minimalSize.height, idealHeight: idealSize.height, maxHeight: maxSize.height)
    }
}

private struct SettingsSectionView<Content: View>: View {

    private let headline: String
    @ViewBuilder private let content: () -> Content

    init(headline: String, @ViewBuilder content: @escaping () -> Content) {
        self.headline = headline
        self.content = content
    }

    var body: some View {
        GroupBox {
            content()
        } label: {
            Text(headline)
                .font(.headline)
                .padding(.bottom, 8)
                .alignmentGuide(.leading, computeValue: { _ in 0 })
        }
        .groupBoxStyle(.automatic)
        .frame(minWidth: 350, idealWidth: 400, maxWidth: 600)
        .padding(.top, 32)
        .padding(.trailing, 10)
        .padding([.leading, .bottom], 0)
    }
}

private struct SettingsAccountSection: View {

    private let viewModel: any SettingsViewModelProtocol

    init(viewModel: any SettingsViewModelProtocol) {
        self.viewModel = viewModel
    }

    var body: some View {
        HStack(spacing: 12) {
            InitialsView(viewModel.initials)

            VStack(alignment: .leading) {
                Text(viewModel.displayName)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)

                Text(verbatim: viewModel.emailAddress)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(Localization.setting_account_manage_account) {
                viewModel.actions.links.manageAccount()
            }

        }
        .frame(maxWidth: .infinity)
        .padding([.top, .bottom], 6)
        .padding([.leading, .trailing], 8)
    }
}

private struct SettingsStorageSection<ViewModel: SettingsViewModelProtocol>: View {

    @ObservedObject private var viewModel: ViewModel

    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            if viewModel.userInfo.isFull {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text(Localization.setting_storage_out_of_storage)
                    } icon: {
                        IconProvider.exclamationCircle
                            .resizable()
                            .frame(width: 16, height: 16)
                    }

                    Text(Localization.setting_storage_out_of_storage_warning)
                }
                .foregroundColor(ColorProvider.SignalDanger)
            }

            HStack {
                ProgressView(
                    value: Double(viewModel.userInfo.usedSpace),
                    total: Double(viewModel.userInfo.maxSpace)
                ) {
                    Text(viewModel.userInfo.storageDescription)
                }
                .tint(viewModel.userInfo.isWarning ? ColorProvider.SignalDanger : ColorProvider.InteractionNorm)

                Spacer(minLength: 55)

                Button(Localization.general_get_more_storage) {
                    viewModel.actions.links.getMoreStorage()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding([.top, .bottom], 12)
        .padding([.leading, .trailing], 8)
    }
}

private struct SettingsSystemSection<ViewModel: SettingsViewModelProtocol>: View {

    @ObservedObject private var viewModel: ViewModel

    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $viewModel.isLaunchOnBootEnabled) {
                Text(Localization.setting_system_launch_on_startup)
                Spacer()
                    .frame(minWidth: 4, maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .toggleStyle(SwitchToggleStyle())
            .tint(ColorProvider.InteractionNorm)
            
            if let message = viewModel.launchOnBootUserFacingMessage {
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(ColorProvider.SignalInfo)
            }

            #if HAS_BUILTIN_UPDATER
            Divider()
                .frame(maxWidth: .infinity)
                .padding([.bottom], 8)
            
            HStack(alignment: .center) {
                switch viewModel.updateAvailability {
                case .readyToInstall:
                    Text(Localization.setting_system_new_version_available)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Spacer(minLength: 16)
                    
                    Button(Localization.setting_system_update_button) {
                        viewModel.actions.app.installUpdate()
                    }
                case .checking:
                    Text(Localization.setting_system_checking_update)
                case .downloading, .extracting:
                    Text(Localization.setting_system_downloading)
                case .upToDate(let version):
                    Text(Localization.setting_system_up_to_date(version: version))
                case .errored(let userFacingMessage):
                    Text(userFacingMessage)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Spacer(minLength: 16)
                    
                    Button(Localization.general_retry) {
                        viewModel.actions.app.checkForUpdates()
                    }
                }
            }
            #endif
        }
        .onAppear {
            #if HAS_BUILTIN_UPDATER
            viewModel.actions.app.checkForUpdates()
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding([.top, .bottom], 12)
        .padding([.leading, .trailing], 8)
    }
}

private struct SettingsFullResyncSection: View {
    
    private let viewModel: any SettingsViewModelProtocol

    init(viewModel: any SettingsViewModelProtocol) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("If your app is not syncing correctly, click to automatically refresh your data. It may take a few minutes depending on how many files you have.")
                
            Spacer(minLength: 4)
            
            Button("Refresh") {
                viewModel.actions.sync.performFullResync()
                viewModel.actions.windows.closeSettingsAndShowMainWindow()
            }
            .buttonStyle(.bordered)
        }
        .padding([.top, .bottom], 12)
        .padding([.leading, .trailing], 8)
    }
}

private struct SettingsGetHelpSection: View {

    private let viewModel: any SettingsViewModelProtocol

    init(viewModel: any SettingsViewModelProtocol) {
        self.viewModel = viewModel
    }

    var additionHelp: AttributedString? {
        let link = SettingsViewModel.supportWebsiteURL.absoluteString
        return try? AttributedString(markdown: Localization.setting_help_additional_help(link: link))
    }

    var body: some View {
        HStack(alignment: .top) {

            VStack(alignment: .leading, spacing: 12) {
                Text(Localization.setting_help_report_encourage_text)

                if let additionHelp {
                    Text(additionHelp)
                }
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 16) {
                Button(Localization.setting_help_report_issue) {
                    viewModel.actions.links.reportBug()
                }
                .buttonStyle(.bordered)

                HideableView(modifier: .option, defaultView: {
                    AsyncButton(progressViewSize: CGSize(width: 16, height: 16)) {
                        viewModel.actions.windows.showLogsInFinder()
                    } label: {
                        Text(Localization.setting_help_show_logs)
                    }
                    .buttonStyle(.bordered)
                }, pressedView: {
                    if RuntimeConfiguration.shared.includeTracesInLogs {
                        Button("Disable detailed logging") {
                            viewModel.actions.app.toggleDetailedLogging()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Detailed logging") {
                            viewModel.actions.app.toggleDetailedLogging()
                        }
                        .buttonStyle(.bordered)
                    }
                })
            }
        }
        .padding([.top, .bottom], 12)
        .padding([.leading, .trailing], 8)
    }
}

private struct SettingsFooterView: View {

    private let viewModel: any SettingsViewModelProtocol

    init(viewModel: any SettingsViewModelProtocol) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                viewModel.actions.account.userRequestedSignOut()
            } label: {
                Label {
                    Text(Localization.menu_text_logout)
                } icon: {
                    IconProvider.arrowOutFromRectangle
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .foregroundColor(ColorProvider.LinkNorm)
            }
            .disabled(viewModel.isSignoutInProgress)
            .buttonStyle(.link)
            .accessibilityIdentifier("SettingsView.Button.signOut")

            Button(Localization.setting_terms_and_condition) {
                viewModel.actions.links.showTermsAndConditions()
            }
            .foregroundColor(ColorProvider.LinkNorm)
            .buttonStyle(.link)
            .accessibilityIdentifier("SettingsView.Button.termsAndConditions")

            Button(Localization.setting_mac_version(version: viewModel.version)) {
                viewModel.actions.links.showReleaseNotes()
            }
            .foregroundColor(ColorProvider.LinkNorm)
            .buttonStyle(.link)
            .accessibilityIdentifier("SettingsView.Button.version")
        }
        .padding(.leading)
        .padding(.top)
    }
}

#if DEBUG

struct SettingsViewPreview: PreviewProvider {

    private final class SettingsViewModelForPreview: SettingsViewModelProtocol {
        
        var userInfo = UserInfo(
            usedSpace: 10_000_000_000,
            maxSpace: 20_000_000_000,
            invoiceState: InvoiceUserState.delinquentMedium,
            isPaid: true)
        var initials: String = "TU"
        var displayName: String = "Test User"
        var emailAddress: String = "testuser@proton.me"
        static var supportWebsiteURL: URL = URL(string: "https://proton.me")!
        var version: String = Constants.versionDigits
        var isStorageWarning: Bool = false
        var isStorageFull: Bool = false
        var isLaunchOnBootEnabled: Bool = true
        var isFullResyncEnabled: Bool = true
        var isSignoutInProgress: Bool = false
        var launchOnBootUserFacingMessage: String?
        var actions = UserActions(delegate: nil)
#if HAS_BUILTIN_UPDATER
        var updateAvailability: UpdateAvailabilityStatus = .checking
#endif
    }

    static var previews: some View {
        SettingsView(viewModel: SettingsViewModelForPreview())
        .previewLayout(.fixed(width: 600, height: 700))
    }
}

#endif
