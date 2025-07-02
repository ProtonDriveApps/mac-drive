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

import FileProvider
import PDFileProvider

/// Protocol for implementing different strategies of performing file operations.
public protocol FileProviderOperationsProtocol {
    
    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (_ item: NSFileProviderItem?,
                                            _ error: Error?) -> Void) -> Progress

    func fetchContents(itemIdentifier: NSFileProviderItemIdentifier,
                       requestedVersion: NSFileProviderItemVersion?,
                       completionHandler: @escaping (_ fileContents: URL?,
                                                     _ item: NSFileProviderItem?,
                                                     _ error: Error?) -> Void) -> Progress

    // swiftlint:disable:next function_parameter_count
    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (_ createdItem: NSFileProviderItem?,
                                                  _ stillPendingFields: NSFileProviderItemFields,
                                                  _ shouldFetchContent: Bool,
                                                  _ error: Error?) -> Void) -> Progress

    // swiftlint:disable:next function_parameter_count
    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (_ item: NSFileProviderItem?,
                                                  _ stillPendingFields: NSFileProviderItemFields,
                                                  _ shouldFetchContent: Bool,
                                                  _ error: Error?) -> Void) -> Progress

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress
}
