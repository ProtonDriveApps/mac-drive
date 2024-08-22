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
import PDLogin_macOS
import ProtonCoreUIFoundations

struct SyncErrorView: View {

    let minimalSize = CGSize(width: 600.0, height: 350)
    let idealSize = CGSize(width: 600.0, height: 350)
    let maxSize = CGSize(width: 1000, height: 800)

    @ObservedObject var vm: SyncErrorViewModel

    var body: some View {
        VStack {
            containerView
                .padding(32)
            Spacer()
        }
        .background(ColorProvider.BackgroundWeak)
    }
}

extension SyncErrorView {

    var containerView: some View {
        VStack(alignment: .center, spacing: 0) {
            headerView
                .padding(.bottom, 10)
            errorsView
            actionsView
        }
        .frame(minWidth: 500, idealWidth: 500, maxWidth: 900, minHeight: minimalSize.height, idealHeight: idealSize.height, maxHeight: maxSize.height)
    }

    var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(vm.errors.count) Sync errors")
                    .font(.system(size: 13))
                    .fontWeight(.semibold)
                    .foregroundColor(ColorProvider.TextNorm)

                Text("The app automatically retries syncing items that fail to sync.")
                    .font(.system(size: 13))
                .foregroundColor(ColorProvider.TextNorm)
            }

            Spacer()
        }
    }

    var errorsView: some View {
        ScrollView {
            VStack(spacing: 17) {
                ForEach($vm.errors) { error in
                    SyncErrorRowView(error: error, baseURL: vm.baseURL)
                }
            }
        }
        .frame(minWidth: 476, idealWidth: 476, maxWidth: 876, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .background(ColorProvider.BackgroundNorm)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .inset(by: 0.5)
                .stroke(Color(red: 0.9, green: 0.9, blue: 0.9), lineWidth: 1)
        )
    }

    var actionsView: some View {
        HStack(alignment: .center, spacing: 16) {
            Spacer()
            Button("Close") {
                vm.closeButtonTapped()
            }
        }
        .padding(.top, 24)
        .frame(height: 48, alignment: .trailing)
        .frame(minWidth: 500, idealWidth: 500, maxWidth: 900)
    }
}
