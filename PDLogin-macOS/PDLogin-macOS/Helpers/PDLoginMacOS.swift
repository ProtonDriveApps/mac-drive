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

import Foundation
import SwiftUI

public class PDLoginMacOS {
    public static let contentHorizontalPadding: CGFloat = 54
    public static let contentWidth: CGFloat = 300
    public static let frameWidth: CGFloat = 420
    public static let frameHeight: CGFloat = 480
    
    public static let bundle = Bundle.module
    
    static var logoImage: some View {
        Image("login_logo", bundle: PDLoginMacOS.bundle)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 188, height: 36)
            .padding(.top, 24)
    }
}
