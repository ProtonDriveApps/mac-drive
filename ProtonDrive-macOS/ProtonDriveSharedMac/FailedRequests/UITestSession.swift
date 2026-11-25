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

#if DEBUG
import Foundation

/// The UI test the app was launched for. The File Provider extension gets no launch environment,
/// so it reads this from the app group.
struct UITestSession: Equatable {
    let dynamicDomain: String?
    /// The running UI test as `Class/method`.
    let testCase: String?
}

struct UITestSessionStore {
    static let key = "uiTestSession"
    private static let dynamicDomainKey = "dynamicDomain"
    private static let testCaseKey = "testCase"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    /// Stores the session when the app is launched for UI tests, and removes it otherwise.
    func updateAtLaunch(arguments: [String], environment: [String: String]) {
        guard arguments.contains("--uitests") else {
            userDefaults.removeObject(forKey: Self.key)
            return
        }
        let values = [
            Self.dynamicDomainKey: environment["DYNAMIC_DOMAIN"],
            Self.testCaseKey: environment["UITEST_CASE"],
        ].compactMapValues { $0?.isEmpty == false ? $0 : nil }
        userDefaults.set(values, forKey: Self.key)
    }

    func read() -> UITestSession? {
        guard let values = userDefaults.dictionary(forKey: Self.key) else { return nil }
        return UITestSession(dynamicDomain: values[Self.dynamicDomainKey] as? String, testCase: values[Self.testCaseKey] as? String)
    }
}

/// Reads the running UI test on every failed request, so a long-lived extension follows the tests.
struct UITestSessionFailedRequestContext: FailedRequestContextResource {
    let process: FailedRequestRecord.Process
    private let store: UITestSessionStore

    init(process: FailedRequestRecord.Process, store: UITestSessionStore) {
        self.process = process
        self.store = store
    }

    var testCase: String? {
        store.read()?.testCase
    }
}
#endif
