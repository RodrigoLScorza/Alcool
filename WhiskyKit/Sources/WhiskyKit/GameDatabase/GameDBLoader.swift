//
//  GameDBLoader.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import os.log

/// Loads game database entries from a bundled JSON resource.
///
/// Follows the ``PatternLoader`` pattern: a caseless enum with static
/// methods for loading from a URL or from the default bundled resource.
public enum GameDBLoader {
    private static let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "GameDBLoader")

    /// The top-level container for ``GameDB.json``.
    private struct GameDBFile: Codable {
        let version: Int
        let entries: [GameDBEntry]
    }

    /// Loads game database entries from the given URL.
    ///
    /// - Parameter url: A file URL pointing to a ``GameDB.json`` file.
    /// - Returns: The decoded array of game entries.
    /// - Throws: If the file cannot be read or decoded.
    public static func loadEntries(from url: URL) throws -> [GameDBEntry] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(GameDBFile.self, from: data)
        return file.entries
    }

    /// Loads the default bundled game database.
    ///
    /// Returns an empty array if the resource is missing or cannot be
    /// decoded. A missing resource is logged rather than fatal in every build:
    /// it happens at runtime (an app moved while running can't find its
    /// resources), so the app keeps working without GameDB matches. In debug
    /// builds, a GameDB.json that fails to decode is still a fatal error.
    public static func loadDefaults() -> [GameDBEntry] {
        guard let url = Bundle.whiskyKitResources?.url(forResource: "GameDB", withExtension: "json") else {
            logger.error("Missing resource: GameDB.json; continuing without GameDB matches")
            return []
        }
        do {
            return try loadEntries(from: url)
        } catch {
            #if DEBUG
            fatalError("Failed to load GameDB: \(error)")
            #else
            return []
            #endif
        }
    }
}
