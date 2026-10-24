//
//  WindowsShortcuts.swift
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

/// The kind of folder an installer put a Windows shortcut in.
public enum WindowsShortcutLocation: String, Codable, Sendable {
    case startMenu
    case desktop
}

/// A folder of a bottle that Windows installers write shortcuts to.
public struct WindowsShortcutFolder: Hashable, Sendable {
    public let url: URL
    public let location: WindowsShortcutLocation
    /// Start Menu shortcuts live in nested program folders; Desktop ones don't.
    public let recursive: Bool
}

/// A Windows shortcut (`.lnk`) file found in one of a bottle's shortcut folders.
public struct WindowsShortcutFile: Hashable, Sendable {
    /// The `.lnk` file.
    public let url: URL
    public let location: WindowsShortcutLocation
    /// When the file last changed, so a rewritten shortcut reads as a change.
    public let modified: Date?

    public init(url: URL, location: WindowsShortcutLocation, modified: Date? = nil) {
        self.url = url
        self.location = location
        self.modified = modified
    }

    /// The name Windows shows for the shortcut: its file name without `.lnk`.
    public var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// Finds the shortcuts Windows installers create in a bottle and decides which
/// of them stand for a program, so they can be mirrored as Mac apps.
public enum WindowsShortcuts {
    /// The Start Menu and Desktop folders of `driveC`, for `wineUsername`.
    public static func folders(driveC: URL, wineUsername: String) -> [WindowsShortcutFolder] {
        let users = driveC.appending(path: "users")
        let startMenu = ["Microsoft", "Windows", "Start Menu"]
        let globalStartMenu = startMenu.reduce(driveC.appending(path: "ProgramData")) { $0.appending(path: $1) }
        let userStartMenu = startMenu.reduce(
            users.appending(path: wineUsername).appending(path: "AppData").appending(path: "Roaming")
        ) { $0.appending(path: $1) }

        return [
            WindowsShortcutFolder(url: globalStartMenu, location: .startMenu, recursive: true),
            WindowsShortcutFolder(url: userStartMenu, location: .startMenu, recursive: true),
            WindowsShortcutFolder(
                url: users.appending(path: wineUsername).appending(path: "Desktop"),
                location: .desktop,
                recursive: false
            ),
            WindowsShortcutFolder(
                url: users.appending(path: "Public").appending(path: "Desktop"),
                location: .desktop,
                recursive: false
            )
        ]
    }

    /// Every `.lnk` file in the bottle's shortcut folders, sorted by path.
    ///
    /// Folders that don't exist are skipped. Hidden files are ignored, and
    /// symbolic links to directories are not followed.
    public static func findShortcuts(driveC: URL, wineUsername: String) -> [WindowsShortcutFile] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var found: [WindowsShortcutFile] = []

        for folder in folders(driveC: driveC, wineUsername: wineUsername) {
            var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
            if !folder.recursive {
                options.insert(.skipsSubdirectoryDescendants)
            }
            guard let enumerator = fileManager.enumerator(
                at: folder.url,
                includingPropertiesForKeys: keys,
                options: options
            )
            else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "lnk" {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile ?? false else { continue }
                found.append(WindowsShortcutFile(
                    url: url,
                    location: folder.location,
                    modified: values?.contentModificationDate
                ))
            }
        }

        return found.sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
    }

    /// Words in a shortcut's name that mark it as something other than the
    /// program: its uninstaller, documentation or web links.
    static let nonProgramNameWords: Set<String> = [
        "uninstall", "uninstaller", "uninst", "desinstalar", "desinstalador", "deinstallieren",
        "readme", "leiame", "manual", "help", "ajuda", "license", "licença", "licenca", "eula",
        "changelog", "website", "homepage", "documentation"
    ]

    /// Multi-word names with the same meaning as ``nonProgramNameWords``.
    static let nonProgramNamePhrases = ["read me", "leia-me", "leia me", "release notes", "web site"]

    /// Executables that are never the program a shortcut is for.
    static let nonProgramExecutables: Set<String> = ["update.exe", "uninstall.exe", "uninst.exe"]

    /// Whether a shortcut named `name` that points at `targetPath` (a Unix path
    /// into the bottle) should become a Mac app.
    ///
    /// Only shortcuts to `.exe` files outside `C:\windows` qualify, and not
    /// uninstallers, documentation or web links. Squirrel-style shortcuts that
    /// target `Update.exe` are skipped as well: the arguments that make them
    /// start the real program are not carried over.
    public static func isProgramShortcut(name: String, targetPath: String) -> Bool {
        let target = targetPath.lowercased()
        let executable = (target as NSString).lastPathComponent
        guard executable.hasSuffix(".exe") else { return false }
        guard !target.contains("/drive_c/windows/") else { return false }
        guard !nonProgramExecutables.contains(executable), !executable.hasPrefix("unins") else { return false }

        let lowered = name.lowercased()
        guard !nonProgramNamePhrases.contains(where: { lowered.contains($0) }) else { return false }
        let words = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return !words.contains(where: { nonProgramNameWords.contains($0) })
    }

    /// The name a program's Mac app gets.
    ///
    /// The shortcut's own name, which is what Windows shows, unless it reads
    /// like a file name, as when an installer names the shortcut after the
    /// executable ("MagicWings.Launcher"). Then the product name from the
    /// executable's version resource ("Magic Wings") reads better.
    public static func preferredName(shortcutName: String, executableURL: URL, productName: String?) -> String {
        let stem = executableURL.deletingPathExtension().lastPathComponent
        let looksLikeFileName = shortcutName.caseInsensitiveCompare(stem) == .orderedSame
            || (!shortcutName.contains(" ") && shortcutName.contains("."))
        guard looksLikeFileName,
              let productName = productName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !productName.isEmpty
        else { return shortcutName }
        return productName
    }

    /// A file-system-safe name for the Mac `.app` that mirrors a shortcut.
    ///
    /// Slashes and colons become dashes, surrounding whitespace and leading
    /// dots are dropped, and the result is capped well below the file-name
    /// limit. An empty result falls back to "Windows Program".
    public static func macAppName(for displayName: String) -> String {
        var name = displayName
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        name = String(name.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Windows Program" : name
    }
}
