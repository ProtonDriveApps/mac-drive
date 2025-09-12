// Copyright (c) 2025 Proton AG
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
import ProtonCoreLogin
import ProtonCoreUIFoundations
import PDUIComponents

enum TwoFAType {
    case totp
    case fido2
}

struct ChooseTwoFAView: View {
    
    let errors = ErrorToastModifier.Stream()
    private let window: NSWindow

    @State private var selectedType: TwoFAType = .fido2

    @ObservedObject var twoFAWithOneTimeCodeViewModel: TwoFAWithOneTimeCodeViewModel
    @ObservedObject var twoFAWithSecurityKeyViewModel: TwoFAWithSecurityKeyViewModel

    init(twoFAWithOneTimeCodeViewModel: TwoFAWithOneTimeCodeViewModel,
         twoFAWithSecurityKeyViewModel: TwoFAWithSecurityKeyViewModel,
         window: NSWindow) {
        self.twoFAWithOneTimeCodeViewModel = twoFAWithOneTimeCodeViewModel
        self.twoFAWithSecurityKeyViewModel = twoFAWithSecurityKeyViewModel
        self.window = window
    }

    var body: some View {
        VStack {
            PDLoginMacOS.logoImage
                .padding(.bottom, 16)
            
            VStack {
                VStack(spacing: 8) {
                    Text("Two-Factor Authentication")
                        .foregroundColor(ColorProvider.TextNorm)
                        .font(.system(size: 17))
                        .fontWeight(.semibold)
                    
                    Text("Please choose how you want to confirm your identity.")
                        .foregroundColor(ColorProvider.TextNorm)
                        .font(.system(size: 12))
                        .fontWeight(.light)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                }
                .padding(4)
                
                Picker("", selection: $selectedType) {
                    Text("Security key")
                        .tag(TwoFAType.fido2)
                    Text("One-time code")
                        .tag(TwoFAType.totp)
                }
                .pickerStyle(.segmented)
                .disabled(twoFAWithOneTimeCodeViewModel.isLoading || twoFAWithSecurityKeyViewModel.isLoading)
                .padding(.vertical, 8)
            }
            .padding(.horizontal, PDLoginMacOS.contentHorizontalPadding)
            .background(ColorProvider.BackgroundNorm)
            .frame(width: PDLoginMacOS.frameWidth)
            
            selectedView
            
            Spacer()
        }
        .background(ColorProvider.BackgroundNorm)
        .frame(width: PDLoginMacOS.frameWidth)
        .frame(idealHeight: PDLoginMacOS.frameHeight, maxHeight: .infinity)
        .errorToast(errors: twoFAWithOneTimeCodeViewModel.errors)
        .errorToast(errors: twoFAWithSecurityKeyViewModel.errors)
    }

    @ViewBuilder
    var selectedView: some View {
        switch selectedType {
        case .totp:
            TwoFAWithOneTimeCodeView(vm: twoFAWithOneTimeCodeViewModel, isNested: true, window: window)
        case .fido2:
            TwoFAWithSecurityKeyView(viewModel: twoFAWithSecurityKeyViewModel, isNested: true, window: window)
        }
    }
}
