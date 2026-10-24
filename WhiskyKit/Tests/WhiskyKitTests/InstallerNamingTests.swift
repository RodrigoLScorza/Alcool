//
//  InstallerNamingTests.swift
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
import Testing
@testable import WhiskyKit

@Suite("Installer naming")
struct InstallerNamingTests {
    private func name(_ file: String, product: String? = nil) -> String? {
        InstallerNaming.bottleName(forInstaller: URL(filePath: "/Downloads/\(file)"), productName: product)
    }

    @Test("The product name wins, without a trailing installer word")
    func productName() {
        #expect(name("MagicWingsInstaller.exe", product: "Magic Wings") == "Magic Wings")
        #expect(name("foo.exe", product: "Crystal of Atlan Setup") == "Crystal of Atlan")
        // Product names keep their dots and their "Windows".
        #expect(name("x.exe", product: "Paint.NET") == "Paint.NET")
        #expect(name("x.exe", product: "Windows Terminal") == "Windows Terminal")
        // A blank product name falls back to the file name.
        #expect(name("SteamSetup.exe", product: "  ") == "Steam")
    }

    @Test("A file name loses installer words and versions", arguments: [
        ("MagicWingsInstaller.exe", "MagicWings"),
        ("SteamSetup.exe", "Steam"),
        ("Steam_Setup.exe", "Steam"),
        ("game-setup-v1.2.3-x64.exe", "game"),
        ("Epic Games Launcher Installer.msi", "Epic Games Launcher"),
        ("Battle.net-Setup.exe", "Battle net")
    ])
    func fileNames(file: String, expected: String) {
        #expect(name(file) == expected)
    }

    @Test("An installer named only for what it is gets no name")
    func nothingLeft() {
        #expect(name("setup.exe") == nil)
        #expect(name("install_x64.exe") == nil)
    }
}
