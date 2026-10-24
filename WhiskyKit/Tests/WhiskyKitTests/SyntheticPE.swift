//
//  SyntheticPE.swift
//  WhiskyKitTests
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

/// Builds a small PE32+ file with the structures the Sommelier reads: an
/// import directory, a delay-load import directory and, for a .NET assembly,
/// a CLI header whose metadata has a `#Strings` heap. Everything lives in one
/// section, mapped at ``sectionRVA`` and stored at ``sectionOffset``.
struct SyntheticPE {
    var machine: UInt16 = 0x8664
    var imports: [String] = []
    var delayImports: [String] = []
    /// The metadata version string; `nil` for a native executable.
    var dotNetVersion: String?
    /// Entries of the `#Strings` heap.
    var dotNetStrings: [String] = []
    /// `StringFileInfo` entries of a version resource; none when empty.
    var versionStrings: [String: String] = [:]

    static let sectionRVA: UInt32 = 0x1000
    static let sectionOffset = 0x200

    /// A data directory entry: its index in the optional header, and where it points.
    private struct Directory {
        let index: Int
        let rva: UInt32
        let size: UInt32
    }

    func data() -> Data {
        var section = Data()
        var directories: [Directory] = []
        if !imports.isEmpty {
            directories.append(Self.appendImports(imports, to: &section))
        }
        if !delayImports.isEmpty {
            directories.append(Self.appendDelayImports(delayImports, to: &section))
        }
        if let dotNetVersion {
            directories.append(Self.appendMetadata(version: dotNetVersion, strings: dotNetStrings, to: &section))
        }
        if !versionStrings.isEmpty {
            directories.append(Self.appendVersionResource(versionStrings, to: &section))
        }
        repeat {
            section.append(0)
        } while section.count % 0x200 != 0
        return headers(sectionSize: section.count, directories: directories) + section
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data().write(to: url)
    }

    // MARK: - Section contents

    private static func rva(_ offset: Int) -> UInt32 {
        sectionRVA + UInt32(offset)
    }

    /// `IMAGE_IMPORT_DESCRIPTOR`s (20 bytes, zero-terminated), then the names.
    private static func appendImports(_ names: [String], to section: inout Data) -> Directory {
        let table = section.count
        let size = (names.count + 1) * 20
        section.append(Data(count: size))
        for (index, name) in names.enumerated() {
            let nameAt = section.count
            section.append(Data(name.utf8) + [0])
            section.put(rva(nameAt), at: table + index * 20 + 12)
            section.put(rva(table), at: table + index * 20 + 16) // FirstThunk: anything non-zero
        }
        return Directory(index: 1, rva: rva(table), size: UInt32(size))
    }

    /// Version 1 (RVA-based) `IMAGE_DELAYLOAD_DESCRIPTOR`s (32 bytes), then the names.
    private static func appendDelayImports(_ names: [String], to section: inout Data) -> Directory {
        let table = section.count
        let size = (names.count + 1) * 32
        section.append(Data(count: size))
        for (index, name) in names.enumerated() {
            let nameAt = section.count
            section.append(Data(name.utf8) + [0])
            section.put(UInt32(1), at: table + index * 32)
            section.put(rva(nameAt), at: table + index * 32 + 4)
        }
        return Directory(index: 13, rva: rva(table), size: UInt32(size))
    }

    /// A CLI header, then a metadata root with one stream, `#Strings`.
    private static func appendMetadata(version: String, strings: [String], to section: inout Data) -> Directory {
        let cliHeader = section.count
        section.append(Data(count: 72))

        let versionField = (Data(version.utf8) + [0]).paddedToFour()
        let heap = strings.reduce(Data([0])) { $0 + Data($1.utf8) + [0] }.paddedToFour()
        let streamHeader = 8 + 12 // offset, size, "#Strings\0" padded to 12

        var metadata = Data()
        metadata.put(UInt32(0x424A_5342), at: 0) // "BSJB"
        metadata.put(UInt16(1), at: 4)
        metadata.put(UInt16(1), at: 6)
        metadata.put(UInt32(versionField.count), at: 12)
        metadata.append(versionField)
        metadata.append(contentsOf: [0, 0, 1, 0]) // flags, one stream
        let header = metadata.count
        metadata.put(UInt32(header + streamHeader), at: header)
        metadata.put(UInt32(heap.count), at: header + 4)
        metadata.append(Data("#Strings".utf8) + [0, 0, 0, 0])
        metadata.append(heap)

        let root = section.count
        section.append(metadata)
        section.put(UInt32(72), at: cliHeader)
        section.put(rva(root), at: cliHeader + 8)
        section.put(UInt32(metadata.count), at: cliHeader + 12)
        return Directory(index: 14, rva: rva(cliHeader), size: 72)
    }

    /// A resource directory with one `RT_VERSION` entry (type → name →
    /// language → data), then its `VS_VERSIONINFO`.
    private static func appendVersionResource(_ strings: [String: String], to section: inout Data) -> Directory {
        let root = section.count
        var directory = Data()
        // Three one-entry directories (16 + 8 bytes each), then the data entry.
        for (level, id) in [UInt32(16), 1, 0x0409].enumerated() {
            let entry = level * 24
            directory.put(UInt16(1), at: entry + 14)
            directory.put(id, at: entry + 16)
            let next = UInt32((level + 1) * 24)
            directory.put(level < 2 ? next | 0x8000_0000 : next, at: entry + 20)
        }
        let info = SyntheticVersionInfo.build(strings)
        let dataEntry = 72
        directory.put(rva(root + dataEntry + 16), at: dataEntry)
        directory.put(UInt32(info.count), at: dataEntry + 4)
        directory.put(UInt32(0), at: dataEntry + 12) // code page and reserved: 16 bytes in all
        section.append(directory)
        section.append(info)
        return Directory(index: 2, rva: rva(root), size: UInt32(directory.count + info.count))
    }

    // MARK: - Headers

    /// The DOS header, `PE\0\0` at 0x40, the COFF and PE32+ optional headers,
    /// and the one section header, padded to ``sectionOffset``.
    private func headers(sectionSize: Int, directories: [Directory]) -> Data {
        var file = Data(count: Self.sectionOffset)
        file.put(UInt16(0x5A4D), at: 0)
        file.put(UInt32(0x40), at: 0x3C)
        file.put(UInt32(0x0000_4550), at: 0x40)

        let coff = 0x44
        file.put(machine, at: coff)
        file.put(UInt16(1), at: coff + 2)
        file.put(UInt16(0xF0), at: coff + 16)

        let optional = coff + 20
        file.put(UInt16(0x20B), at: optional)
        file.put(UInt64(0x1_4000_0000), at: optional + 24)
        file.put(UInt32(16), at: optional + 108)
        for directory in directories {
            file.put(directory.rva, at: optional + 112 + directory.index * 8)
            file.put(directory.size, at: optional + 112 + directory.index * 8 + 4)
        }

        let sectionHeader = optional + 0xF0
        file.replaceSubrange(sectionHeader ..< sectionHeader + 8, with: Data(".rdata\0\0".utf8))
        file.put(UInt32(sectionSize), at: sectionHeader + 8)
        file.put(Self.sectionRVA, at: sectionHeader + 12)
        file.put(UInt32(sectionSize), at: sectionHeader + 16)
        file.put(UInt32(Self.sectionOffset), at: sectionHeader + 20)
        return file
    }

    // MARK: - Samples

    static let wpfApp = SyntheticPE(
        machine: 0x014C,
        imports: ["mscoree.dll"],
        dotNetVersion: "v4.0.30319",
        dotNetStrings: ["<Module>", "PresentationFramework", "WindowsBase", "MainWindow"]
    )
    static let winFormsApp = SyntheticPE(
        machine: 0x014C,
        imports: ["mscoree.dll"],
        dotNetVersion: "v4.0.30319",
        dotNetStrings: ["System.Windows.Forms", "Form1"]
    )
    /// What Electron's executable imports: no Direct3D at startup.
    static let chromiumShell = SyntheticPE(
        imports: ["kernel32.dll", "user32.dll", "ffmpeg.dll"],
        delayImports: ["d3d11.dll", "dxgi.dll", "d3d12.dll"]
    )
    /// An engine game: Direct3D 11 at startup, Direct3D 12 on demand.
    static let direct3D11Game = SyntheticPE(
        imports: ["kernel32.dll", "d3d11.dll", "dxgi.dll", "d3d9.dll"],
        delayImports: ["d3d12.dll"]
    )
}

/// Builds `VS_VERSIONINFO` blocks: length, value length, type, UTF-16 key,
/// padding, value, padding, children.
enum SyntheticVersionInfo {
    static func build(_ strings: [String: String]) -> Data {
        let entries = strings.sorted { $0.key < $1.key }.map { key, value in
            block(key: key, value: utf16(value), textWords: value.utf16.count + 1, children: [])
        }
        let table = block(key: "040904b0", value: Data(), textWords: 0, children: entries)
        let fileInfo = block(key: "StringFileInfo", value: Data(), textWords: 0, children: [table])
        var fixed = Data(count: 52)
        fixed.put(UInt32(0xFEEF_04BD), at: 0)
        return block(key: "VS_VERSION_INFO", value: fixed, binary: true, children: [fileInfo])
    }

    private static func utf16(_ string: String) -> Data {
        string.utf16.reduce(into: Data()) { data, unit in
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        } + [0, 0]
    }

    private static func block(key: String, value: Data, textWords: Int, children: [Data]) -> Data {
        block(key: key, value: value, binary: false, valueLength: textWords, children: children)
    }

    private static func block(key: String, value: Data, binary: Bool, children: [Data]) -> Data {
        block(key: key, value: value, binary: binary, valueLength: value.count, children: children)
    }

    private static func block(key: String, value: Data, binary: Bool, valueLength: Int, children: [Data]) -> Data {
        var data = Data(count: 6)
        data.put(UInt16(valueLength), at: 2)
        data.put(UInt16(binary ? 0 : 1), at: 4)
        data.append(utf16(key))
        data = data.paddedToFour() + value
        for child in children {
            data = data.paddedToFour() + child
        }
        data.put(UInt16(data.count), at: 0)
        return data
    }
}

private extension Data {
    /// Writes `value` little-endian at `offset`, growing the data if needed.
    mutating func put(_ value: some FixedWidthInteger, at offset: Int) {
        let bytes = Swift.withUnsafeBytes(of: value.littleEndian) { Array($0) }
        if count < offset + bytes.count {
            append(Data(count: offset + bytes.count - count))
        }
        replaceSubrange(offset ..< offset + bytes.count, with: bytes)
    }

    func paddedToFour() -> Data {
        self + Data(count: (4 - count % 4) % 4)
    }
}
