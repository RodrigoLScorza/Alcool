//
//  WindowsShortcutsTests.swift
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

@Suite("Windows Shortcuts Tests")
struct WindowsShortcutsTests {
    /// A throwaway `drive_c` with the folders a fresh bottle has.
    private func makeDriveC() throws -> URL {
        let driveC = FileManager.default.temporaryDirectory
            .appending(path: "WindowsShortcutsTests-\(UUID().uuidString)")
            .appending(path: "drive_c")
        for folder in WindowsShortcuts.folders(driveC: driveC, wineUsername: "crossover") {
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        }
        return driveC
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x4C, 0x00, 0x00, 0x00]).write(to: url)
    }

    // MARK: - Folders

    @Test("Start Menu folders are searched recursively, Desktop folders are not")
    func folderLayout() {
        let driveC = URL(fileURLWithPath: "/tmp/bottle/drive_c")
        let folders = WindowsShortcuts.folders(driveC: driveC, wineUsername: "crossover")
        let paths = folders.map { $0.url.path(percentEncoded: false) }

        #expect(paths == [
            "/tmp/bottle/drive_c/ProgramData/Microsoft/Windows/Start Menu",
            "/tmp/bottle/drive_c/users/crossover/AppData/Roaming/Microsoft/Windows/Start Menu",
            "/tmp/bottle/drive_c/users/crossover/Desktop",
            "/tmp/bottle/drive_c/users/Public/Desktop"
        ])
        #expect(folders.map(\.location) == [.startMenu, .startMenu, .desktop, .desktop])
        #expect(folders.map(\.recursive) == [true, true, false, false])
    }

    // MARK: - Finding shortcuts

    @Test("Finds .lnk files in every folder, in nested Start Menu folders and with any case")
    func findsShortcuts() throws {
        let driveC = try makeDriveC()
        defer { try? FileManager.default.removeItem(at: driveC.deletingLastPathComponent()) }
        let folders = WindowsShortcuts.folders(driveC: driveC, wineUsername: "crossover")

        try touch(folders[1].url.appending(path: "Programs/Magic Wings/Magic Wings.lnk"))
        try touch(folders[0].url.appending(path: "Programs/Tool.LNK"))
        try touch(folders[2].url.appending(path: "Game.lnk"))
        try touch(folders[3].url.appending(path: "Shared Game.lnk"))

        let found = WindowsShortcuts.findShortcuts(driveC: driveC, wineUsername: "crossover")

        #expect(Set(found.map(\.displayName)) == ["Magic Wings", "Tool", "Game", "Shared Game"])
        #expect(found.first { $0.displayName == "Magic Wings" }?.location == .startMenu)
        #expect(found.first { $0.displayName == "Game" }?.location == .desktop)
        #expect(found.allSatisfy { $0.modified != nil })
    }

    @Test("Skips other files, hidden files and shortcuts nested under the Desktop")
    func skipsNonShortcuts() throws {
        let driveC = try makeDriveC()
        defer { try? FileManager.default.removeItem(at: driveC.deletingLastPathComponent()) }
        let desktop = WindowsShortcuts.folders(driveC: driveC, wineUsername: "crossover")[2].url

        try touch(desktop.appending(path: "notes.txt"))
        try touch(desktop.appending(path: "Site.url"))
        try touch(desktop.appending(path: ".hidden.lnk"))
        try touch(desktop.appending(path: "Folder/Nested.lnk"))

        #expect(WindowsShortcuts.findShortcuts(driveC: driveC, wineUsername: "crossover").isEmpty)
    }

    @Test("A bottle without shortcut folders yields nothing")
    func missingFolders() {
        let driveC = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString)")
        #expect(WindowsShortcuts.findShortcuts(driveC: driveC, wineUsername: "crossover").isEmpty)
    }

    // MARK: - Program shortcuts

    @Test("Shortcuts to installed executables are programs")
    func programShortcuts() {
        let launcher = "/b/drive_c/users/crossover/AppData/Local/MagicWings/MagicWings.Launcher.exe"
        #expect(WindowsShortcuts.isProgramShortcut(name: "Magic Wings", targetPath: launcher))
        #expect(WindowsShortcuts.isProgramShortcut(name: "Game", targetPath: "/b/drive_c/Program Files/Game/GAME.EXE"))
        #expect(WindowsShortcuts.isProgramShortcut(name: "Helper Tool", targetPath: "/b/drive_c/Games/helper.exe"))
    }

    @Test("Uninstallers, documents, web links and system programs are not")
    func nonProgramShortcuts() {
        let game = "/b/drive_c/Program Files/Game"
        #expect(!WindowsShortcuts.isProgramShortcut(name: "Uninstall Game", targetPath: "\(game)/uninstall.exe"))
        #expect(!WindowsShortcuts.isProgramShortcut(name: "Remove", targetPath: "\(game)/unins000.exe"))
        #expect(!WindowsShortcuts.isProgramShortcut(name: "Desinstalar Jogo", targetPath: "\(game)/game.exe"))
        #expect(!WindowsShortcuts.isProgramShortcut(name: "Read Me", targetPath: "\(game)/game.exe"))
        #expect(!WindowsShortcuts.isProgramShortcut(name: "Game Manual", targetPath: "\(game)/manual.pdf"))
        #expect(!WindowsShortcuts.isProgramShortcut(name: "Game Website", targetPath: "\(game)/site.url"))
        #expect(!WindowsShortcuts.isProgramShortcut(name: "Notepad", targetPath: "/b/drive_c/windows/notepad.exe"))
        #expect(!WindowsShortcuts.isProgramShortcut(name: "Discord", targetPath: "/b/drive_c/Discord/Update.exe"))
    }

    // MARK: - Mac app names

    @Test("Mac app names drop path separators, leading dots and surrounding spaces")
    func macAppNames() {
        #expect(WindowsShortcuts.macAppName(for: "Magic Wings") == "Magic Wings")
        #expect(WindowsShortcuts.macAppName(for: "Game: Remastered / Deluxe") == "Game- Remastered - Deluxe")
        #expect(WindowsShortcuts.macAppName(for: "..hidden") == "hidden")
        #expect(WindowsShortcuts.macAppName(for: "   ") == "Windows Program")
        #expect(WindowsShortcuts.macAppName(for: String(repeating: "a", count: 300)).count == 200)
    }

    // MARK: - Registry

    @Test("The registry matches shortcuts case-insensitively, relative to drive_c")
    func registryKeys() {
        let driveC = URL(fileURLWithPath: "/tmp/bottle/drive_c")
        let link = driveC.appending(path: "users/crossover/Desktop/Game.lnk")
        var registry = MacShortcutRegistry()
        registry.markProcessed(link, driveC: driveC)

        #expect(MacShortcutRegistry.key(for: link, driveC: driveC) == "users/crossover/desktop/game.lnk")
        #expect(registry.contains(driveC.appending(path: "Users/CrossOver/Desktop/GAME.lnk"), driveC: driveC))
        #expect(!registry.contains(driveC.appending(path: "users/crossover/Desktop/Other.lnk"), driveC: driveC))
    }

    @Test("The registry keeps its keys when the bottle moves")
    func registryAfterMove() {
        let link = "users/crossover/Desktop/Game.lnk"
        var registry = MacShortcutRegistry()
        registry.markProcessed(
            URL(fileURLWithPath: "/old/bottle/drive_c").appending(path: link),
            driveC: URL(fileURLWithPath: "/old/bottle/drive_c")
        )
        let moved = URL(fileURLWithPath: "/new/place/bottle/drive_c")
        #expect(registry.contains(moved.appending(path: link), driveC: moved))
    }

    @Test("The registry round-trips through the bottle folder")
    func registryPersistence() throws {
        let bottle = FileManager.default.temporaryDirectory.appending(path: "registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bottle) }
        let driveC = bottle.appending(path: "drive_c")

        #expect(MacShortcutRegistry.load(from: bottle) == MacShortcutRegistry())

        var registry = MacShortcutRegistry()
        registry.markProcessed(driveC.appending(path: "users/Public/Desktop/Game.lnk"), driveC: driveC)
        try registry.save(to: bottle)

        #expect(MacShortcutRegistry.load(from: bottle) == registry)
    }

    @Test("An unreadable registry starts over empty")
    func corruptRegistry() throws {
        let bottle = FileManager.default.temporaryDirectory.appending(path: "registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bottle) }
        try Data("not a plist".utf8).write(to: bottle.appending(path: MacShortcutRegistry.fileName))

        #expect(MacShortcutRegistry.load(from: bottle) == MacShortcutRegistry())
    }

    // MARK: - Shortcut bundle Info.plist

    @Test("A shortcut's Info.plist names the app and, when given, its icon")
    func shortcutInfoPlist() throws {
        func decode(_ data: Data) throws -> [String: Any] {
            try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }

        let plain = try decode(ShortcutCreator.infoPlist(name: "Rock & Roll <Deluxe>"))
        #expect(plain["CFBundleName"] as? String == "Rock & Roll <Deluxe>")
        #expect(plain["CFBundleExecutable"] as? String == "launch")
        #expect(plain["CFBundleIconFile"] == nil)

        let withIcon = try decode(ShortcutCreator.infoPlist(name: "Game", iconFileName: "AppIcon"))
        #expect(withIcon["CFBundleIconFile"] as? String == "AppIcon")
    }
}
