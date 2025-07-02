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

// This wrapper takes a completion block and ensures that after the completion block is called once,
// the reference to it is no longer retained.
public final class CompletionBlockWrapper<A, B, C, D> {
    
    private var completionBlock: (A, B, C, D) -> Void
    
    public init(_ completionBlock: @escaping () -> Void)
    where A == Void, B == Void, C == Void, D == Void {
        self.completionBlock = { _, _, _, _ in
            completionBlock()
        }
    }
    
    public init(_ completionBlock: @escaping (A) -> Void)
    where B == Void, C == Void, D == Void {
        self.completionBlock = { a, _, _, _ in
            completionBlock(a)
        }
    }
    
    public init(_ completionBlock: @escaping (A, B) -> Void) where C == Void, D == Void {
        self.completionBlock = { a, b, _, _ in
            completionBlock(a, b)
        }
    }
    
    public init(_ completionBlock: @escaping (A, B, C) -> Void) where D == Void {
        self.completionBlock = { a, b, c, _ in
            completionBlock(a, b, c)
        }
    }
    
    public init(_ completionBlock: @escaping (A, B, C, D) -> Void) {
        self.completionBlock = completionBlock
    }
    
    public func callAsFunction() where A == Void, B == Void, C == Void, D == Void {
        completionBlock((), (), (), ())
        reset()
    }
    
    public func callAsFunction(_ a: A) where B == Void, C == Void, D == Void {
        completionBlock(a, (), (), ())
        reset()
    }
    
    public func callAsFunction(_ a: A, _ b: B) where C == Void, D == Void {
        completionBlock(a, b, (), ())
        reset()
    }
    
    public func callAsFunction(_ a: A, _ b: B, _ c: C) where D == Void {
        completionBlock(a, b, c, ())
        reset()
    }
    
    public func callAsFunction(_ a: A, _ b: B, _ c: C, _ d: D) {
        completionBlock(a, b, c, d)
        reset()
    }
    
    private func reset() {
        // deallocate previous block
        completionBlock = { _, _, _, _ in }
    }
}
