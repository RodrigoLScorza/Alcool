//
//  PortableExecutableReader+Version.swift
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

extension PortableExecutableReader {
    /// The `StringFileInfo` keys kept from a version resource.
    static let versionKeys: Set<String> = ["ProductName", "FileDescription", "CompanyName"]

    private static let versionResourceType: UInt32 = 16 // RT_VERSION
    private static let maxVersionResource = 64 * 1_024

    /// The ``versionKeys`` of the first `RT_VERSION` resource, read through the
    /// three-level resource directory (type, name, language).
    static func versionStrings(image: PEImageLayout, resourceRVA: UInt32) -> [String: String] {
        guard let root = image.offset(ofRVA: resourceRVA),
              let nameDirectory = directoryEntry(in: root, id: versionResourceType, image: image, base: root),
              let languageDirectory = directoryEntry(in: nameDirectory, id: nil, image: image, base: root),
              let dataEntry = directoryEntry(in: languageDirectory, id: nil, image: image, base: root),
              let dataRVA = image.file.uint32(at: dataEntry),
              let size = image.file.uint32(at: dataEntry + 4),
              let offset = image.offset(ofRVA: dataRVA),
              let data = image.file.read(at: offset, count: min(Int(size), maxVersionResource))
        else { return [:] }
        return versionStrings(inVersionInfo: data)
    }

    /// Where an entry of the `IMAGE_RESOURCE_DIRECTORY` at `directory` points,
    /// as a file offset: the entry with ID `id`, or the first one for `nil`.
    private static func directoryEntry(
        in directory: UInt64, id: UInt32?, image: PEImageLayout, base: UInt64
    ) -> UInt64? {
        guard let named = image.file.uint16(at: directory + 12),
              let numbered = image.file.uint16(at: directory + 14)
        else { return nil }
        let count = min(Int(named) + Int(numbered), 256)
        for index in 0 ..< count {
            let entry = directory + 16 + UInt64(index * 8)
            guard let name = image.file.uint32(at: entry),
                  let target = image.file.uint32(at: entry + 4)
            else { return nil }
            // Named entries come first and have the high bit set; an ID never does.
            if let id, name != id { continue }
            return base + UInt64(target & 0x7FFF_FFFF)
        }
        return nil
    }

    /// The ``versionKeys`` of a `VS_VERSIONINFO` block.
    ///
    /// Every block is `wLength`, `wValueLength`, `wType`, a NUL-terminated
    /// UTF-16 key, padding to 4 bytes, the value, padding, and child blocks.
    /// Only `StringFileInfo` → string table → string is walked.
    static func versionStrings(inVersionInfo data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        guard let root = VersionBlock(bytes, at: 0), root.key == "VS_VERSION_INFO" else { return [:] }
        var strings: [String: String] = [:]
        for fileInfo in root.children(in: bytes) where fileInfo.key == "StringFileInfo" {
            for table in fileInfo.children(in: bytes) {
                for entry in table.children(in: bytes) where versionKeys.contains(entry.key) {
                    let value = entry.stringValue(in: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty, strings[entry.key] == nil {
                        strings[entry.key] = value
                    }
                }
            }
        }
        return strings
    }
}

/// One block of a `VS_VERSIONINFO` resource.
private struct VersionBlock {
    let start: Int
    let end: Int
    let key: String
    let valueStart: Int
    /// In bytes. `wValueLength` counts UTF-16 units for text values.
    let valueLength: Int
    let childrenStart: Int

    init?(_ bytes: [UInt8], at start: Int) {
        func word(_ offset: Int) -> Int? {
            offset + 1 < bytes.count ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 : nil
        }
        guard let length = word(start), length >= 6, start + length <= bytes.count,
              let valueWords = word(start + 2), let type = word(start + 4)
        else { return nil }

        var units: [UInt16] = []
        var cursor = start + 6
        while let unit = word(cursor), cursor < start + length {
            cursor += 2
            if unit == 0 { break }
            units.append(UInt16(unit))
        }
        self.start = start
        end = start + length
        key = String(decoding: units, as: UTF16.self)
        valueStart = Self.aligned(cursor)
        valueLength = type == 1 ? valueWords * 2 : valueWords
        childrenStart = Self.aligned(valueStart + valueLength)
    }

    func children(in bytes: [UInt8]) -> [VersionBlock] {
        var blocks: [VersionBlock] = []
        var cursor = childrenStart
        while cursor < end, blocks.count < 256, let block = VersionBlock(bytes, at: cursor), block.end <= end {
            blocks.append(block)
            cursor = Self.aligned(block.end)
        }
        return blocks
    }

    func stringValue(in bytes: [UInt8]) -> String {
        let stop = min(valueStart + valueLength, end)
        var units: [UInt16] = []
        var cursor = valueStart
        while cursor + 1 < stop {
            let unit = UInt16(bytes[cursor]) | UInt16(bytes[cursor + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
            cursor += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func aligned(_ offset: Int) -> Int {
        (offset + 3) & ~3
    }
}
