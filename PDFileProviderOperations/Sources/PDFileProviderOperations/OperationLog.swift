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

import Foundation
import PDCore

struct OperationLog<T> {

    let identifier: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
    let operation: FileProviderOperation
    let info: T?

    var identifierPart: String { "{\(identifier)}" }
    var operationPart: String { " — \(operation.descriptionForLogs)" }
    var infoPart: String { info.map { " — \($0)" } ?? "" }

    static func logStart(of operation: FileProviderOperation, additional info: T?) -> OperationLog<T> {
        let logEntry = OperationLog<T>(operation: operation, info: info)
        Log.info(logEntry.identifierPart + " Start" + logEntry.operationPart + logEntry.infoPart, domain: .fileProvider)
        return logEntry
    }

    func logEnd(error: Swift.Error? = nil) {
        logEnd(Void?.none, error: error)
    }

    func logEnd<S>(_ moreInfo: S?, error: Swift.Error? = nil) {
        let prefix = error.map { _ in " Errored" } ?? " Finish"
        let moreInfoPart = moreInfo.map { " — \($0)" } ?? ""
        if let error {
            Log.warning(identifierPart + prefix + operationPart + infoPart + moreInfoPart + " — \(error.localizedDescription)", domain: .fileProvider)
        } else {
            Log.info(identifierPart + prefix + operationPart + infoPart + moreInfoPart, domain: .fileProvider)
        }
    }
}
