//
//  PortableExecutableReader.swift
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

/// The CPU an executable was built for, from its COFF header.
public enum ExecutableMachine: String, Codable, Sendable {
    case x86
    case x64
    case arm64
    case unknown

    /// The machine a COFF header's `Machine` field names.
    init(coffMachine: UInt16) {
        self = switch coffMachine {
        case 0x014C: .x86
        case 0x8664: .x64
        case 0xAA64: .arm64
        default: .unknown
        }
    }
}

/// What a PE file declares about itself: its machine, the libraries it
/// imports, and, for a .NET assembly, its runtime and referenced assemblies.
///
/// Read with bounded, random-access reads, so a 150 MB game executable costs
/// a few kilobytes of I/O, and never by running the file.
struct PortableExecutableFacts: Equatable, Sendable {
    var machine: ExecutableMachine = .unknown
    /// DLLs the loader maps at startup, lowercased.
    var importedLibraries: Set<String> = []
    /// DLLs loaded on first use, lowercased. Engines delay-load optional
    /// renderers this way (Unity and Unreal delay-load `d3d12.dll`), so these
    /// say what a program can use, not what it renders with by default.
    var delayLoadedLibraries: Set<String> = []
    /// The .NET metadata version string (such as `v4.0.30319`), or `nil` for
    /// a native executable.
    var dotNetRuntimeVersion: String?
    /// The entries of the .NET `#Strings` heap that name assemblies this
    /// reader looks for (see ``PortableExecutableReader/knownAssemblies``).
    var referencedAssemblies: Set<String> = []
}

/// A minimal reader for the parts of a PE file the Sommelier needs.
///
/// It follows the PE/COFF and ECMA-335 layouts directly: the import and
/// delay-load import directories for DLL names, and the CLI header's metadata
/// root for the `#Strings` heap. Malformed or truncated files make it throw or
/// return what it could read; it never reads past the end of the file or more
/// than a capped amount from any one structure.
enum PortableExecutableReader {
    enum ReadError: Error {
        case notPortableExecutable
    }

    /// Assemblies whose presence in the `#Strings` heap identifies a UI stack.
    static let knownAssemblies: Set<String> = [
        "PresentationFramework", "PresentationCore", "WindowsBase", "System.Xaml", "System.Windows.Forms"
    ]

    private static let importDirectory = 1
    private static let delayImportDirectory = 13
    private static let clrDirectory = 14
    private static let maxDescriptors = 1_024
    private static let maxStringsHeap = 32 * 1_024 * 1_024

    static func read(url: URL) throws -> PortableExecutableFacts {
        let file = try BinaryFile(url: url)
        defer { file.close() }

        guard file.uint16(at: 0) == 0x5A4D, // "MZ"
              let peOffset = file.uint32(at: 0x3C).map(UInt64.init),
              file.uint32(at: peOffset) == 0x0000_4550 // "PE\0\0"
        else { throw ReadError.notPortableExecutable }

        let coff = peOffset + 4
        guard let machineValue = file.uint16(at: coff),
              let sectionCount = file.uint16(at: coff + 2),
              let optionalSize = file.uint16(at: coff + 16)
        else { throw ReadError.notPortableExecutable }

        let optional = coff + 20
        guard let magic = file.uint16(at: optional), magic == 0x10B || magic == 0x20B else {
            throw ReadError.notPortableExecutable
        }
        let isPE32Plus = magic == 0x20B
        let imageBase = isPE32Plus
            ? file.uint64(at: optional + 24) ?? 0
            : UInt64(file.uint32(at: optional + 28) ?? 0)
        let directoryCount = file.uint32(at: optional + (isPE32Plus ? 108 : 92)) ?? 0
        let directories = optional + (isPE32Plus ? 112 : 96)

        let image = ImageLayout(
            file: file,
            sectionTable: optional + UInt64(optionalSize),
            sectionCount: Int(sectionCount)
        )
        func directory(_ index: Int) -> (rva: UInt32, size: UInt32)? {
            guard index < directoryCount,
                  let rva = file.uint32(at: directories + UInt64(index * 8)),
                  let size = file.uint32(at: directories + UInt64(index * 8) + 4),
                  rva != 0, size != 0
            else { return nil }
            return (rva, size)
        }

        var facts = PortableExecutableFacts()
        facts.machine = ExecutableMachine(coffMachine: machineValue)

        if let imports = directory(importDirectory) {
            facts.importedLibraries.formUnion(importNames(image: image, rva: imports.rva))
        }
        if let delayed = directory(delayImportDirectory) {
            facts.delayLoadedLibraries = delayImportNames(image: image, rva: delayed.rva, imageBase: imageBase)
        }
        if let clr = directory(clrDirectory) {
            readDotNetMetadata(image: image, cliHeaderRVA: clr.rva, into: &facts)
        }
        return facts
    }

    // MARK: - Imports

    /// Names from `IMAGE_IMPORT_DESCRIPTOR`s (20 bytes, name RVA at +12).
    private static func importNames(image: ImageLayout, rva: UInt32) -> Set<String> {
        var names: Set<String> = []
        for index in 0 ..< maxDescriptors {
            guard let descriptor = image.offset(ofRVA: rva + UInt32(index * 20)),
                  let nameRVA = image.file.uint32(at: descriptor + 12),
                  let firstThunk = image.file.uint32(at: descriptor + 16)
            else { break }
            if nameRVA == 0, firstThunk == 0 { break }
            if let name = image.string(atRVA: nameRVA) {
                names.insert(name.lowercased())
            }
        }
        return names
    }

    /// Names from `IMAGE_DELAYLOAD_DESCRIPTOR`s (32 bytes, name at +4). Version
    /// 1 descriptors (attribute bit 0) hold RVAs, older ones virtual addresses.
    private static func delayImportNames(image: ImageLayout, rva: UInt32, imageBase: UInt64) -> Set<String> {
        var names: Set<String> = []
        for index in 0 ..< maxDescriptors {
            guard let descriptor = image.offset(ofRVA: rva + UInt32(index * 32)),
                  let attributes = image.file.uint32(at: descriptor),
                  let nameField = image.file.uint32(at: descriptor + 4)
            else { break }
            if nameField == 0 { break }
            let nameRVA: UInt32 = if attributes & 1 == 1 {
                nameField
            } else {
                UInt32(truncatingIfNeeded: UInt64(nameField) &- imageBase)
            }
            if let name = image.string(atRVA: nameRVA) {
                names.insert(name.lowercased())
            }
        }
        return names
    }

    // MARK: - .NET metadata

    /// Reads the metadata root the CLI header points at: its version string,
    /// and the `#Strings` heap, checked for ``knownAssemblies``.
    private static func readDotNetMetadata(
        image: ImageLayout,
        cliHeaderRVA: UInt32,
        into facts: inout PortableExecutableFacts
    ) {
        let file = image.file
        guard let cliHeader = image.offset(ofRVA: cliHeaderRVA),
              let metadataRVA = file.uint32(at: cliHeader + 8),
              let root = image.offset(ofRVA: metadataRVA),
              file.uint32(at: root) == 0x424A_5342, // "BSJB"
              let versionLength = file.uint32(at: root + 12), versionLength <= 255
        else { return }

        let versionBytes = file.read(at: root + 16, count: Int(versionLength)) ?? Data()
        let version = String(bytes: versionBytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        facts.dotNetRuntimeVersion = version.isEmpty ? "unknown" : version

        // Flags (2 bytes), then the stream count and the stream headers.
        let afterVersion = root + 16 + UInt64(versionLength)
        guard let streamCount = file.uint16(at: afterVersion + 2) else { return }
        var header = afterVersion + 4
        for _ in 0 ..< min(Int(streamCount), 16) {
            guard let offset = file.uint32(at: header),
                  let size = file.uint32(at: header + 4),
                  let nameData = file.read(at: header + 8, count: 32),
                  let terminator = nameData.firstIndex(of: 0)
            else { return }
            let name = String(bytes: nameData[nameData.startIndex ..< terminator], encoding: .utf8)
            // The name and its terminator, padded to a 4-byte boundary.
            let nameLength = terminator - nameData.startIndex + 1
            header += 8 + UInt64((nameLength + 3) & ~3)

            if name == "#Strings" {
                let heap = file.read(at: root + UInt64(offset), count: min(Int(size), maxStringsHeap)) ?? Data()
                facts.referencedAssemblies = knownAssemblies(inStringsHeap: heap)
            }
        }
    }

    /// The ``knownAssemblies`` that appear as whole entries of a `#Strings` heap.
    static func knownAssemblies(inStringsHeap heap: Data) -> Set<String> {
        var found: Set<String> = []
        for entry in heap.split(separator: 0, omittingEmptySubsequences: true) {
            if let string = String(bytes: entry, encoding: .utf8), knownAssemblies.contains(string) {
                found.insert(string)
            }
        }
        return found
    }
}

/// Maps RVAs to file offsets through a PE file's section table.
private struct ImageLayout {
    struct SectionRange {
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawOffset: UInt32
        let rawSize: UInt32
    }

    let file: BinaryFile
    let sections: [SectionRange]

    init(file: BinaryFile, sectionTable: UInt64, sectionCount: Int) {
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
private final class BinaryFile {
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
