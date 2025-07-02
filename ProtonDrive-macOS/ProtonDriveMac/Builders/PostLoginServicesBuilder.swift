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
import PDCore
import PDUploadVerifier

protocol PostLoginServicesBuilder {
    func build(with observers: [EventsListener], activityObserver: @escaping ((NSUserActivity) -> Void)) -> PostLoginServices
}

class ConcretePostLoginServicesBuilder: PostLoginServicesBuilder {
    private let initialServices: InitialServices
    private let eventProcessingMode: DriveEventsLoopMode
    private let eventLoopInterval: Double

    init(initialServices: InitialServices, eventProcessingMode: DriveEventsLoopMode, eventLoopInterval: Double) {
        self.initialServices = initialServices
        self.eventProcessingMode = eventProcessingMode
        self.eventLoopInterval = eventLoopInterval
    }

    func build(with observers: [EventsListener], activityObserver: @escaping ((NSUserActivity) -> Void)) -> PostLoginServices {
        PostLoginServices(initialServices: initialServices,
                          appGroup: Constants.appGroup,
                          eventObservers: observers,
                          eventProcessingMode: eventProcessingMode,
                          eventLoopInterval: eventLoopInterval,
                          uploadVerifierFactory: ConcreteUploadVerifierFactory(),
                          activityObserver: activityObserver)
    }
}
