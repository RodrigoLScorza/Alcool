//
//  InstallerNaming.swift
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

/// Names for what an installer brings in.
public enum InstallerNaming {
    /// Words an installer's file name carries that name the installer, not
    /// the program: "MagicWingsInstaller", "game-setup-x64".
    private static let installerWords: Set<String> = [
        "setup", "installer", "install", "x64", "x86", "win64", "win32", "windows", "web", "online", "offline"
    ]

    /// The name of the bottle made for an installer: the product name in its
    /// version resource, else its file name without installer words and
    /// version numbers. `nil` when nothing is left ("setup.exe").
    public static func bottleName(forInstaller url: URL, productName: String?) -> String? {
        if let productName, let product = product(productName) {
            return product
        }
        return fileName(url.deletingPathExtension().lastPathComponent)
    }

    /// A product name as it is, but for a trailing "Setup" or "Installer":
    /// "Paint.NET" and "Windows Terminal" are names, not file names.
    private static func product(_ name: String) -> String? {
        var words = name.split(separator: " ").map(String.init)
        if words.count > 1, let last = words.last, ["setup", "installer", "install"].contains(last.lowercased()) {
            words.removeLast()
        }
        let result = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }

    private static func fileName(_ name: String) -> String? {
        let separated = name.replacingOccurrences(of: "[_\\-.]+", with: " ", options: .regularExpression)
        let words = separated.split(separator: " ").compactMap { word -> String? in
            var word = String(word)
            // Glued on, as in "MagicWingsInstaller" or "SteamSetup".
            for suffix in ["Installer", "Setup", "installer", "setup"] where word.count > suffix.count {
                if word.hasSuffix(suffix) {
                    word.removeLast(suffix.count)
                    break
                }
            }
            let lowered = word.lowercased()
            let isVersion = lowered.range(of: "^v?[0-9]+$", options: .regularExpression) != nil
            return installerWords.contains(lowered) || isVersion ? nil : word
        }
        let result = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }
}
