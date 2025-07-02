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

import Cocoa
import PDCore
import FileProvider

class ProtonFile: NSDocument {
    var interactor: ProtonFileNonAuthenticatedURLInteractorProtocol?
    var urlCoordinator: URLCoordinatorProtocol?
    var errorViewModel: ProtonFileErrorViewModelProtocol?

    private var opening = false
    private var url: URL?
    private var typeName: String?

    override func read(from url: URL, ofType typeName: String) throws {
        Log.debug("📜 start reading", domain: .protonDocs)
        self.url = url
        self.typeName = typeName
    }

    func finishReading() {
        guard let url, let typeName else {
            assert(false)
            Log.error("URL must be set before finishReading is called", domain: .protonDocs)
            close()
            return
        }

        openDocumentInBrowser(from: url, ofType: typeName)
    }

    private func openDocumentInBrowser(from url: URL, ofType typeName: String) {
        Log.debug("📜 openDocumentInBrowser called", domain: .protonDocs)
        guard !opening else {
            // Already opening
            return
        }

        opening = true
        NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { [weak self] identifier, domainIdentifier, error in
            guard let self else {
                return
            }

            defer {
                close()
                opening = false
            }

            guard let urlCoordinator,
                  let errorViewModel else {
                Log.error("urlCoordinator and errorViewModel must be set before a Proton Document is read", domain: .protonDocs)
                return
            }

            if let error {
                Log.info(error.localizedDescription, domain: .protonDocs)

                let userError = ProtonFileOpeningError.invalidIncomingURL
                errorViewModel.handleError(userError)
                Log.info(userError.localizedDescription, domain: .protonDocs)

                return
            }

            guard let interactor else {
                let error = ProtonFileOpeningError.notSignedIn
                errorViewModel.handleError(error)
                Log.info(error.localizedDescription, domain: .protonDocs)

                return
            }

            guard let identifier else {
                let error = ProtonFileOpeningError.missingIdentifier
                errorViewModel.handleError(error)
                Log.info(error.localizedDescription, domain: .protonDocs)

                return
            }

            guard let nodeIdentifier = NodeIdentifier(identifier) else {
                let error = ProtonFileOpeningError.missingIdentifier
                errorViewModel.handleError(error)
                Log.error("Could not open Proton Document because of failure to convert NSFileProviderItemIdentifier to NodeIdentifier", domain: .protonDocs)

                return
            }

            guard let type = ProtonFileType(uti: typeName) else {
                let error = ProtonFileOpeningError.invalidFileType
                errorViewModel.handleError(error)
                Log.info(error.localizedDescription, domain: .protonDocs)
                return
            }

            do {
                let url = try interactor.getURL(for: nodeIdentifier, ofType: type)
                urlCoordinator.openExternal(url: url)
            } catch {
                errorViewModel.handleError(error)
                Log.error(error: error, domain: .protonDocs)
            }
        }
    }
}
