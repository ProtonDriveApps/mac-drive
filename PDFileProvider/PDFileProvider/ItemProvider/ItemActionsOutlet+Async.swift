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

import FileProvider
import Foundation
import PDCore

// swiftlint:disable function_parameter_count
extension ItemActionsOutlet {

    @discardableResult
    public func deleteItem(tower: Tower,
                           identifier: NSFileProviderItemIdentifier,
                           baseVersion version: NSFileProviderItemVersion?,
                           options: NSFileProviderDeleteItemOptions = [],
                           request: NSFileProviderRequest? = nil,
                           completionHandler: @escaping (Error?) -> Void) -> Progress
    {
        let version = version ?? NSFileProviderItemVersion()

        let task = Task { [weak self] in
            do {
                guard !Task.isCancelled else { return }
                try await self?.deleteItem(tower: tower, identifier: identifier, baseVersion: version, options: options, request: request)
                Log.info("Successfully deleted item", domain: .fileProvider)
                guard !Task.isCancelled else { return }
                completionHandler(nil)
            } catch {
                guard !Task.isCancelled else { return }
                Log.error("Delete item error: \(error.localizedDescription)", domain: .fileProvider)
                completionHandler(error)
            }
        }
        
        return Progress {
            Log.info("Delete item cancelled", domain: .fileProvider)
            task.cancel()
            completionHandler(CocoaError(.userCancelled))
        }
    }
    
    @discardableResult
    public func modifyItem(tower: Tower,
                           item: NSFileProviderItem,
                           baseVersion version: NSFileProviderItemVersion?,
                           changedFields: NSFileProviderItemFields,
                           contents newContents: URL?,
                           options: NSFileProviderModifyItemOptions? = nil,
                           request: NSFileProviderRequest? = nil,
                           changeObserver: SyncChangeObserver? = nil,
                           completionHandler: @escaping Completion) -> Progress
    {
        let version = version ?? NSFileProviderItemVersion()

        let task = Task { [weak self] in
            do {
                guard !Task.isCancelled else { return }
                guard let (item, fields, needUpload) = try await self?.modifyItem(
                    tower: tower, item: item, baseVersion: version, changedFields: changedFields,
                    contents: newContents, options: options, request: request, changeObserver: changeObserver
                ) else { return }
                Log.info("Successfully modified item", domain: .fileProvider)
                guard !Task.isCancelled else { return }
                completionHandler(item, fields, needUpload, nil)
            } catch {
                Log.error("Modify item error: \(error.localizedDescription)", domain: .fileProvider)
                guard !Task.isCancelled else { return }
                completionHandler(nil, [], false, error)
            }
        }
        
        return Progress {
            Log.info("Modify item cancelled", domain: .fileProvider)
            task.cancel()
            completionHandler(nil, [], false, CocoaError(.userCancelled))
        }
    }
    
    @discardableResult
    public func createItem(tower: Tower,
                           basedOn itemTemplate: NSFileProviderItem,
                           fields: NSFileProviderItemFields = [],
                           contents url: URL?,
                           options: NSFileProviderCreateItemOptions = [],
                           request: NSFileProviderRequest? = nil,
                           completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress
    {
        let task = Task { [weak self] in
            do {
                guard let self, !Task.isCancelled else { return }
                let (item, fields, needUpload) = try await self.createItem(
                    tower: tower, basedOn: itemTemplate, fields: fields, contents: url, options: options, request: request
                )
                Log.info("Successfully created item", domain: .fileProvider)
                guard !Task.isCancelled else { return }
                completionHandler(item, fields, needUpload, nil)
            } catch {
                Log.error("Create item error: \(error.localizedDescription)", domain: .fileProvider)
                guard !Task.isCancelled else { return }
                completionHandler(nil, [], false, error)
            }
        }
        
        return Progress {
            Log.info("Create item cancelled", domain: .fileProvider)
            task.cancel()
            completionHandler(nil, [], false, CocoaError(.userCancelled))
        }
    }

}
// swiftlint:enable function_parameter_count
