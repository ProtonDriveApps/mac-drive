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

class ProtonFileController: NSDocumentController {
    private let messageHandler = UserMessageHandler()
    private let errorViewModel: ProtonFileErrorViewModelProtocol

    // Indicates if the app is ready to be able to handle the opening of documents
    private var ready = false {
        didSet {
            if oldValue == false && ready == true {
                finishReadingAllDocuments()
            }
        }
    }

    // Ensures the controller instance is only marked ready AFTER the tower is
    // explicitely set (either nil on non-nil)
    var tower: Tower? {
        didSet {
            Log.debug("📜 did set tower", domain: .protonDocs)
            ready = true
        }
    }

    override init() {
        errorViewModel = ProtonFileErrorViewModel(messageHandler: messageHandler)
        super.init()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        Log.debug("📜 makeDocument called", domain: .protonDocs)

        let document = try super.makeDocument(withContentsOf: url, ofType: typeName)
        Log.debug("📜 super.makeDocument called", domain: .protonDocs)
        guard let protonFile = document as? ProtonFile else {
            let error = ProtonFileOpeningError.invalidFileType
            errorViewModel.handleError(error)
            Log.error(error: error, domain: .protonDocs)
            throw error
        }
        
        protonFile.urlCoordinator = macOSURLCoordinator()
        protonFile.errorViewModel = errorViewModel

        addDocument(protonFile)

        guard ready else {
            Log.debug("📜 controller not ready", domain: .protonDocs)
            return protonFile
        }

        finishReadingAllDocuments()

        return protonFile
    }

    private func finishReadingAllDocuments() {
        Log.debug("📜 Docs waiting to finish: \(documents.count)", domain: .protonDocs)
        // Open any docs that are waiting
        documents.forEach { document in
            if let protonFile = document as? ProtonFile {
                if let tower {
                    protonFile.interactor = ProtonFileOpeningFactory().makeNonAuthenticatedURLInteractor(tower: tower)
                }

                protonFile.finishReading()
            }
        }
    }
}
