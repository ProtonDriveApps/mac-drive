//
//  Folder+Sequence.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 22/01/2024.
//

import Foundation

public extension Folder {
    /// A sequence of child locations contained within a given folder.
    /// You obtain an instance of this type by accessing either `files`
    /// or `subfolders` on a `Folder` instance.
    struct ChildSequence<Child: Location>: Sequence {
        let folder: Folder
        let fileManager: FileManager
        var isRecursive: Bool
        var includeHidden: Bool

        public func makeIterator() -> ChildIterator<Child> {
            return ChildIterator(
                folder: folder,
                fileManager: fileManager,
                isRecursive: isRecursive,
                includeHidden: includeHidden,
                reverseTopLevelTraversal: false
            )
        }
    }

    /// The type of iterator used by `ChildSequence`. You don't interact
    /// with this type directly. See `ChildSequence` for more information.
    struct ChildIterator<Child: Location>: IteratorProtocol {
        private let folder: Folder
        private let fileManager: FileManager
        private let isRecursive: Bool
        private let includeHidden: Bool
        private let reverseTopLevelTraversal: Bool
        private lazy var itemNames = loadItemNames()
        private var index = 0
        private var nestedIterators = [ChildIterator<Child>]()

        init(folder: Folder,
                         fileManager: FileManager,
                         isRecursive: Bool,
                         includeHidden: Bool,
                         reverseTopLevelTraversal: Bool) {
            self.folder = folder
            self.fileManager = fileManager
            self.isRecursive = isRecursive
            self.includeHidden = includeHidden
            self.reverseTopLevelTraversal = reverseTopLevelTraversal
        }

        public mutating func next() -> Child? {
            guard index < itemNames.count else {
                guard var nested = nestedIterators.first else {
                    return nil
                }

                guard let child = nested.next() else {
                    nestedIterators.removeFirst()
                    return next()
                }

                nestedIterators[0] = nested
                return child
            }

            let name = itemNames[index]
            index += 1

            if !includeHidden {
                guard !name.hasPrefix(".") else { return next() }
            }

            let childPath = folder.path + name.removingPrefix("/")
            let childStorage = try? Storage<Child>(path: childPath, fileManager: fileManager)
            let child = childStorage.map(Child.init)

            if isRecursive {
                let childFolder = (child as? Folder) ?? (try? Folder(
                    storage: Storage(path: childPath, fileManager: fileManager)
                ))

                if let childFolder = childFolder {
                    let nested = ChildIterator(
                        folder: childFolder,
                        fileManager: fileManager,
                        isRecursive: true,
                        includeHidden: includeHidden,
                        reverseTopLevelTraversal: false
                    )

                    nestedIterators.append(nested)
                }
            }

            return child ?? next()
        }

        private mutating func loadItemNames() -> [String] {
            let contents = try? fileManager.contentsOfDirectory(atPath: folder.path)
            let names = contents?.sorted() ?? []
            return reverseTopLevelTraversal ? names.reversed() : names
        }
    }
}

public extension Folder.ChildSequence {

    /// Count the number of locations contained within this sequence.
    /// Complexity: `O(N)`.
    func count() -> Int {
        return reduce(0) { count, _ in count + 1 }
    }
    
    /// Gather the names of all of the locations contained within this sequence.
    /// Complexity: `O(N)`.
    func names() -> [String] {
        return map { $0.name }
    }

    /// Move all locations within this sequence to a new parent folder.
    /// - parameter folder: The folder to move all locations to.
    /// - throws: `LocationError` if the move couldn't be completed.
    func move(to folder: Folder) throws {
        try forEach { try $0.move(to: folder) }
    }
}
