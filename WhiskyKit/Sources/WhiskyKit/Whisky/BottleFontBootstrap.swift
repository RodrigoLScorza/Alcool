//
//  BottleFontBootstrap.swift
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

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "BottleFontBootstrap")

/// Copies a small set of host fonts into a bottle's `drive_c/windows/Fonts` directory
/// so Unity titles using dynamic font fallback don't render missing glyphs.
public enum BottleFontBootstrap {
    /// Host font candidates to copy into a bottle. The first existing path for each
    /// destination filename wins; missing host fonts are skipped silently.
    private static let candidates: [(destination: String, sources: [String])] = [
        ("Arial Unicode.ttf", ["/Library/Fonts/Arial Unicode.ttf"]),
        ("Arial.ttf", ["/Library/Fonts/Arial.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf"]),
        ("Tahoma.ttf", ["/Library/Fonts/Tahoma.ttf", "/System/Library/Fonts/Supplemental/Tahoma.ttf"])
    ]

    /// The core Windows UI fonts that macOS ships in its Supplemental
    /// folder: Arial, Times New Roman and Verdana in all four styles, the set
    /// CrossOver installs for .NET apps. WPF and WinForms layouts ask for
    /// them by name and fall back to wrong metrics without them.
    static let coreFontCandidates: [(destination: String, sources: [String])] = {
        let styles = ["", " Bold", " Italic", " Bold Italic"]
        return ["Arial", "Times New Roman", "Verdana"].flatMap { family in
            styles.map { style in
                let file = "\(family)\(style).ttf"
                return (file, ["/Library/Fonts/\(file)", "/System/Library/Fonts/Supplemental/\(file)"])
            }
        }
    }()

    /// Copies missing fonts into `<bottlePrefix>/drive_c/windows/Fonts`.
    /// Idempotent: existing destination files are left untouched.
    public static func copySystemFonts(toPrefix prefix: URL) {
        copy(candidates, toPrefix: prefix)
    }

    /// Copies the missing core UI fonts (see ``coreFontCandidates``) into the bottle.
    /// Idempotent: existing destination files are left untouched.
    public static func copyCoreFonts(toPrefix prefix: URL) {
        copy(coreFontCandidates, toPrefix: prefix)
    }

    private static func copy(_ fonts: [(destination: String, sources: [String])], toPrefix prefix: URL) {
        let dest = prefix.appending(path: "drive_c/windows/Fonts")
        let manager = FileManager.default
        try? manager.createDirectory(at: dest, withIntermediateDirectories: true)

        for (filename, sources) in fonts {
            let destURL = dest.appending(path: filename)
            guard !manager.fileExists(atPath: destURL.path(percentEncoded: false)) else { continue }
            guard let source = sources.first(where: { manager.fileExists(atPath: $0) }) else { continue }
            do {
                try manager.copyItem(at: URL(fileURLWithPath: source), to: destURL)
                logger.info("Bootstrapped \(filename, privacy: .public) into bottle fonts")
            } catch {
                logger.warning("Failed to copy \(filename, privacy: .public): \(error.localizedDescription)")
            }
        }
    }
}
