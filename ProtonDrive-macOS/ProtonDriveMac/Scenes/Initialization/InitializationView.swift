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
import PDLogin_macOS
import ProtonCoreUIFoundations

struct InitializationView: View {
    
    @ObservedObject private var coordinator: InitializationCoordinator
    
    init(coordinator: InitializationCoordinator) {
        self.coordinator = coordinator
    }
    
    var body: some View {
        VStack {
            Image("login_logo", bundle: PDLoginMacOS.bundle)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 188, height: 36)
                .padding(.top, 24)
                .padding(.bottom, 30)
            
            switch coordinator.initializationViewState {
            case .left(let initializationProgress):
                Text("Setting up your drive")
                    .foregroundColor(ColorProvider.TextNorm)
                    .font(.system(size: 17))
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)
                
                Text(verbatim: initializationProgress.message)
                    .foregroundStyle(ColorProvider.TextNorm)
                    .font(.system(size: 13))
                    .fontWeight(.light)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .multilineTextAlignment(.center)
                
                if initializationProgress.totalValue > 0 && initializationProgress.currentValue >= 0 {
                    
                    Spacer()
                    
                    ProgressView(value: Double(initializationProgress.currentValue),
                                 total: Double(initializationProgress.totalValue))
                        .progressViewStyle(LinearProgressViewStyle())
                        .foregroundStyle(ColorProvider.InteractionNormActive)
                        .padding(.bottom, 50)
                }
                
            case .right(let initializationFailure):
                
                Text("Setup failed due to an error")
                    .foregroundColor(ColorProvider.TextNorm)
                    .font(.system(size: 17))
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)
                
                Text(verbatim: initializationFailure.error.localizedDescription)
                    .foregroundStyle(ColorProvider.TextNorm)
                    .font(.system(size: 13))
                    .fontWeight(.light)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .multilineTextAlignment(.center)
                
                Spacer()
                
                LoginButton(title: "Retry", isLoading: .constant(false), action: initializationFailure.retry)
                    .accessibilityIdentifier("InitializationView.Button.retry")
                    .padding(.bottom, 50)
            }
            
            Spacer()
        }
        .padding(.horizontal, PDLoginMacOS.contentHorizontalPadding)
        .background(ColorProvider.BackgroundNorm)
        .frame(width: PDLoginMacOS.frameWidth)
        .frame(idealHeight: PDLoginMacOS.frameHeight, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.top)
    }
}
