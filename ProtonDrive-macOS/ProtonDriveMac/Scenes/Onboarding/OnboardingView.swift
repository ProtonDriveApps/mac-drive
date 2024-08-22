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

import AppKit
import Combine
import PDLogin_macOS
import ProtonCoreUIFoundations
import PDCore
import SwiftUI

final class OnboardingController: ObservableObject {

    @Published var isLoading: Bool = false
    var endAction: () -> Void = {}
    var finishSubject = PassthroughSubject<Void, Never>()

    init() {
        self.endAction = {
            self.finishSubject.send()
        }
    }

}

struct OnboardingView: View {
    
    @ObservedObject private var controller: OnboardingController

    init(controller: OnboardingController) {
        self.controller = controller
    }

    var body: some View {
        VStack {

            Image("login_logo", bundle: PDLoginMacOS.bundle)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 188, height: 36)
                .padding(.top, 24)
                .padding(.bottom, 30)

            VStack(spacing: 0) {

                Text("You’re nearly there!")
                    .foregroundColor(ColorProvider.TextNorm)
                    .font(.system(size: 17))
                    .fontWeight(.semibold)
                    .padding(.bottom, 8)

                Text("Open your folder and click Enable to finish setting up Proton Drive on your Mac.")
                    .foregroundColor(ColorProvider.TextNorm)
                    .font(.system(size: 13))
                    .fontWeight(.light)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)

                Image("onboarding")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 300, height: 160)
                    .padding(.vertical, 24)

                LoginButton(title: "Open your Proton Drive folder", isLoading: $controller.isLoading, action: controller.endAction)
                    .accessibilityIdentifier("OnboardingView.Button.openDriveFolder")
            }
            .frame(width: 300)

            Spacer()

        }
        .padding(.horizontal, 54)
        .background(ColorProvider.BackgroundNorm)
        .frame(width: 420)
        .frame(idealHeight: 480, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.top)
    }
}

struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(controller: OnboardingController())
            .frame(width: 420, height: 480)
    }
}
