//
//  MacShortcutRegistry.swift
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

/// Remembers which Windows shortcuts of a bottle were already handled, so each
/// one is pinned and mirrored as a Mac app once. A Mac app the user deletes is
/// not created again, and the `.lnk` files themselves are left alone.
///
/// Stored next to the bottle's metadata, keyed by each shortcut's path
/// relative to `drive_c`, so moving the bottle keeps the record valid.
public struct MacShortcutRegistry: Codable, Equatable, Sendable {
    /// The registry's file name inside the bottle folder.
    public static let fileName = "AlcoolShortcuts.plist"

    /// Lowercased paths, relative to `drive_c`, of the shortcuts handled so far.
    public private(set) var processedLinks: Set<String>

    public init(processedLinks: Set<String> = []) {
        self.processedLinks = processedLinks
    }

    /// The bottle's registry, or an empty one when it has none or it can't be read.
    public static func load(from bottleURL: URL) -> MacShortcutRegistry {
        let url = bottleURL.appending(path: fileName)
        guard let data = try? Data(contentsOf: url),
              let registry = try? PropertyListDecoder().decode(MacShortcutRegistry.self, from: data)
        else { return MacShortcutRegistry() }
        return registry
    }

    /// Writes the registry into the bottle folder.
    public func save(to bottleURL: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(self)
        try data.write(to: bottleURL.appending(path: Self.fileName), options: .atomic)
    }

    /// The key for `link`: its path relative to `driveC`, lowercased because
    /// bottles live on case-insensitive volumes and Windows paths ignore case.
    public static func key(for link: URL, driveC: URL) -> String {
        let linkPath = link.standardizedFileURL.path(percentEncoded: false)
        var root = driveC.standardizedFileURL.path(percentEncoded: false)
        if !root.hasSuffix("/") {
            root += "/"
        }
        let relative = linkPath.hasPrefix(root) ? String(linkPath.dropFirst(root.count)) : linkPath
        return relative.lowercased()
    }

    public func contains(_ link: URL, driveC: URL) -> Bool {
        processedLinks.contains(Self.key(for: link, driveC: driveC))
    }

    public mutating func markProcessed(_ link: URL, driveC: URL) {
        processedLinks.insert(Self.key(for: link, driveC: driveC))
    }
}
