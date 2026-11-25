// Copyright (c) 2026 Proton AG
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

import ProtonCoreNetworking

/// ProtonCore session factory for the API services of the app and the File Provider extension.
/// DEBUG builds record failed requests while a UI test runs.
enum DriveSessionFactory {
    static func makeForApp() -> SessionFactoryInterface {
#if DEBUG
        makeRecording(process: .app)
#else
        SessionFactory.instance
#endif
    }

    static func makeForFileProviderExtension() -> SessionFactoryInterface {
#if DEBUG
        makeRecording(process: .extension)
#else
        SessionFactory.instance
#endif
    }

#if DEBUG
    private static func makeRecording(process: FailedRequestRecord.Process) -> SessionFactoryInterface {
        let store = UITestSessionStore(userDefaults: Constants.appGroup.userDefaults)
        let recorder = FailedRequestRecorder(context: UITestSessionFailedRequestContext(process: process, store: store),
                                             resource: UnifiedLogFailedRequestResource())
        return FailedRequestRecordingSessionFactory(factory: SessionFactory.instance, recorder: recorder)
    }
#endif
}
