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

struct SettingsView<ViewModel: SettingsViewModelProtocol>: View {

    let minimalSize = CGSize(width: 500.0, height: 500)
    let idealSize = CGSize(width: 600.0, height: 720)
    let maxSize = CGSize(width: 800, height: 800)

    private var viewModel: ViewModel

    init(viewModel: ViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionView(headline: "Account") {
                    SettingsAccountSection(viewModel: viewModel)
                }

                SettingsSectionView(headline: "Storage") {
                    SettingsStorageSection(viewModel: viewModel)
                }
                
                SettingsSectionView(headline: "System") {
                    SettingsSystemSection(viewModel: viewModel)
                }

                SettingsSectionView(headline: "Get help") {
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

            Button("Manage account") {
                viewModel.manageAccount()
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

    private var storageText: String {
        let currentStorage = ByteCountFormatter.storageSizeString(forByteCount: viewModel.currentStorageInBytes)
        let maxStorage = ByteCountFormatter.storageSizeString(forByteCount: viewModel.maxStorageInBytes)
        return "\(currentStorage) of \(maxStorage) used"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            if viewModel.isStorageFull {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("Out of storage")
                    } icon: {
                        IconProvider.exclamationCircle
                            .resizable()
                            .frame(width: 16, height: 16)
                    }

                    Text("Syncing has been paused. Please upgrade or free up space to resume syncing.")
                }
                .foregroundColor(ColorProvider.SignalDanger)
            }

            HStack {
                ProgressView(
                    value: Double(viewModel.currentStorageInBytes),
                    total: Double(viewModel.maxStorageInBytes)
                ) {
                    Text(storageText)
                }
                .tint(viewModel.isStorageWarning ? ColorProvider.SignalDanger : ColorProvider.InteractionNorm)

                Spacer(minLength: 55)

                Button("Get more storage") {
                    viewModel.getMoreStorage()
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
                Text("Launch on startup")
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
                    Text("New version available")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Spacer(minLength: 16)
                    
                    Button("Update now") {
                        viewModel.installUpdate()
                    }
                case .checking:
                    Text("Checking for update ...")
                case .downloading, .extracting:
                    Text("Downloading new version ...")
                case .upToDate(let version):
                    Text("Proton Drive is up to date: v\(version)")
                case .errored(let userFacingMessage):
                    Text(userFacingMessage)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Spacer(minLength: 16)
                    
                    Button("Retry") {
                        viewModel.checkForUpdates()
                    }
                }
            }
            #endif
        }
        .onAppear {
            #if HAS_BUILTIN_UPDATER
            viewModel.checkForUpdates()
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding([.top, .bottom], 12)
        .padding([.leading, .trailing], 8)
    }
}

private struct SettingsGetHelpSection: View {

    private let viewModel: any SettingsViewModelProtocol

    init(viewModel: any SettingsViewModelProtocol) {
        self.viewModel = viewModel
    }

    var string: AttributedString {
        do {
            return try AttributedString(markdown: "[support website](\(viewModel.supportWebsiteURL.absoluteString)).")
        } catch {
            return AttributedString()
        }
    }

    var body: some View {
        HStack(alignment: .top) {

            VStack(alignment: .leading, spacing: 12) {
                Text("If you are facing any problems, please report the issue.")

                Text("You will find additional help on our ") + Text(string)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 16) {
                Button("Report an issue") {
                    viewModel.reportIssue()
                }
                .buttonStyle(.bordered)

                AsyncButton(progressViewSize: CGSize(width: 16, height: 16)) {
                    try? await viewModel.showLogsInFinder()
                } label: {
                    Text("Show logs")
                }
                .buttonStyle(.bordered)
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
                viewModel.signOut()
            } label: {
                Label {
                    Text("Sign out")
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

            Button("Terms and Conditions") {
                viewModel.showTermsAndConditions()
            }
            .foregroundColor(ColorProvider.LinkNorm)
            .buttonStyle(.link)
            .accessibilityIdentifier("SettingsView.Button.termsAndConditions")

            Button("Version \(viewModel.version)") {
                viewModel.showReleaseNotes()
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
        var currentStorageInBytes: Int64 = 10_000_000_000
        var maxStorageInBytes: Int64 = 20_000_000_000
        var initials: String = "TU"
        var displayName: String = "Test User"
        var emailAddress: String = "testuser@proton.me"
        var supportWebsiteURL: URL = URL(string: "https://proton.me")!
        var version: String = Constants.versionDigits
        var isStorageWarning: Bool = false
        var isStorageFull: Bool = false
        var isLaunchOnBootEnabled: Bool = true
        var isLoadingLogs: Bool = false
        var isSignoutInProgress: Bool = false
        var launchOnBootUserFacingMessage: String?
        var updateAvailability: UpdateAvailabilityStatus = .checking

        func manageAccount() {}
        func getMoreStorage() {}
        func reportIssue() {}
        func showLogsInFinder() async {}
        func showSupportWebsite() {}
        func signOut() {}
        func showTermsAndConditions() {}
        func installUpdate() {}
        func checkForUpdates() {}
        func showReleaseNotes() {}
    }

    static var previews: some View {
        SettingsView(viewModel: SettingsViewModelForPreview())
        .previewLayout(.fixed(width: 600, height: 700))
    }
}

#endif
