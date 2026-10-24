//
//  PEImage.swift
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

/// Maps RVAs to file offsets through a PE file's section table.
struct PEImageLayout {
    struct SectionRange {
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawOffset: UInt32
        let rawSize: UInt32
    }

    let file: PEBinaryFile
    let sections: [SectionRange]

    init(file: PEBinaryFile, sectionTable: UInt64, sectionCount: Int) {
        self.file = file
        sections = (0 ..< min(sectionCount, 96)).compactMap { index in
            let header = sectionTable + UInt64(index * 40)
            guard let virtualSize = file.uint32(at: header + 8),
                  let virtualAddress = file.uint32(at: header + 12),
                  let rawSize = file.uint32(at: header + 16),
                  let rawOffset = file.uint32(at: header + 20)
            else { return nil }
            return SectionRange(
                virtualAddress: virtualAddress,
                virtualSize: virtualSize,
                rawOffset: rawOffset,
                rawSize: rawSize
            )
        }
    }

    func offset(ofRVA rva: UInt32) -> UInt64? {
        for section in sections {
            let span = max(section.virtualSize, section.rawSize)
            guard rva >= section.virtualAddress, rva - section.virtualAddress < span else { continue }
            let delta = rva - section.virtualAddress
            guard delta < section.rawSize else { return nil }
            return UInt64(section.rawOffset) + UInt64(delta)
        }
        return nil
    }

    /// A NUL-terminated ASCII string at `rva`, up to 256 bytes.
    func string(atRVA rva: UInt32) -> String? {
        guard let offset = offset(ofRVA: rva),
              let data = file.read(at: offset, count: 256),
              let end = data.firstIndex(of: 0), end > data.startIndex
        else { return nil }
        return String(bytes: data[data.startIndex ..< end], encoding: .utf8)
    }
}

/// Bounded little-endian reads from a file.
final class PEBinaryFile {
    private let handle: FileHandle
    let size: UInt64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = (try? handle.seekToEnd()) ?? 0
    }

    func close() {
        try? handle.close()
    }

    func read(at offset: UInt64, count: Int) -> Data? {
        guard count > 0, offset < size else { return nil }
        let available = Int(min(UInt64(count), size - offset))
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: available)
        } catch {
            return nil
        }
    }

    func uint16(at offset: UInt64) -> UInt16? {
        integer(at: offset)
    }

    func uint32(at offset: UInt64) -> UInt32? {
        integer(at: offset)
    }

    func uint64(at offset: UInt64) -> UInt64? {
        integer(at: offset)
    }

    private func integer<T: FixedWidthInteger>(at offset: UInt64) -> T? {
        let width = MemoryLayout<T>.size
        guard let data = read(at: offset, count: width), data.count == width else { return nil }
        return data.reversed().reduce(T.zero) { ($0 << 8) | T($1) }
    }
}
