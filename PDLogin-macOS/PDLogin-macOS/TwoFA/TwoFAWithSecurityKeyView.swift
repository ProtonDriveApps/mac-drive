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
import ProtonCoreUIFoundations

struct TwoFAWithSecurityKeyView: View {
    @ObservedObject var vm: TwoFAWithSecurityKeyViewModel
    private let window: NSWindow
    var isNested: Bool = false
    
    init(viewModel: TwoFAWithSecurityKeyViewModel, isNested: Bool = false, window: NSWindow) {
        self.vm = viewModel
        self.isNested = isNested
        self.window = window
    }

    var body: some View {
        VStack {
            
            if !isNested {
                PDLoginMacOS.logoImage
                    .padding(.bottom, 16)
            }
            
            VStack(spacing: 8) {
                if isNested {
                    Text("Present a security key linked to your Proton Account.")
                        .foregroundColor(ColorProvider.TextNorm)
                        .font(.system(size: 12))
                        .fontWeight(.light)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                } else {
                    VStack(spacing: 8) {
                        Text("Two-factor authentication")
                            .foregroundColor(ColorProvider.TextNorm)
                            .font(.system(size: 17))
                            .fontWeight(.semibold)
                        
                        Text("Present a security key linked to your Proton Account.")
                            .foregroundColor(ColorProvider.TextNorm)
                            .font(.system(size: 12))
                            .fontWeight(.light)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    }
                    .padding(4)
                }
                
                LinkButton(title: "Learn more") {
                    vm.learnMore()
                }
                
                Image("physical-key", bundle: PDLoginMacOS.bundle)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding([.top, .horizontal], 8)
                    .padding(.bottom, 16)
                    .frame(width: 144)

                LoginButton(title: "Authenticate", isLoading: $vm.isLoading) {
                    vm.startSignature()
                }
            }
            .frame(width: PDLoginMacOS.contentWidth)

            Spacer()
        }
        .padding(.horizontal, PDLoginMacOS.contentHorizontalPadding)
        .background(ColorProvider.BackgroundNorm)
        .frame(width: PDLoginMacOS.frameWidth)
        .frame(idealHeight: PDLoginMacOS.frameHeight, maxHeight: .infinity)
        .if(!isNested) { $0.errorToast(errors: vm.errors) }
    }
}
