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

import Foundation

/// ProtonCore 37.3.0 merges equal labels by incrementing the first event's value,
/// which corrupts histogram measurements. Identity keeps observations distinct
/// locally; encoding only the original labels preserves the metric's wire schema.
/// Create a fresh wrapper per observation. Copies retain the same identity.
struct HistogramObservationLabels<Labels: Encodable & Equatable>: Encodable, Equatable {
    private let labels: Labels
    private let observationID = UUID()

    init(labels: Labels) {
        self.labels = labels
    }

    func encode(to encoder: Encoder) throws {
        try labels.encode(to: encoder)
    }
}
