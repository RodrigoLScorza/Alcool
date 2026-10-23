//
//  Wine+Sommelier.swift
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

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "Sommelier")

/// The registry value that makes WPF render in software.
///
/// WPF draws through Direct3D 9. No backend Alcool ships translates
/// Direct3D 9, so it lands on wined3d's OpenGL path, which on macOS leaves
/// WPF windows blank (`GL_INVALID_FRAMEBUFFER_OPERATION` from `glClear`).
/// Software rendering draws them correctly. The value is per user, so it
/// covers every WPF app in the bottle.
enum WPFSoftwareRendering {
    static let registryKey = #"HKEY_CURRENT_USER\Software\Microsoft\Avalon.Graphics"#
    static let valueName = "DisableHWAcceleration"

    /// What the bottle has for the value.
    enum State: Equatable {
        /// Software rendering is on.
        case enabled
        /// The value isn't set, so the Sommelier may set it.
        case missing
        /// Someone set the value to something else; it is left alone.
        case setOtherwise
        /// `user.reg` can't be read, so nothing is known.
        case unknown
    }

    static func state(bottleURL: URL) -> State {
        guard let names = WineRegistryFile.valueNames(bottleURL: bottleURL, key: registryKey) else {
            return .unknown
        }
        guard names.contains(where: { $0.caseInsensitiveCompare(valueName) == .orderedSame }) else {
            return .missing
        }
        let value = WineRegistryFile.readValue(bottleURL: bottleURL, key: registryKey, valueName: valueName)
        return value?.lowercased() == "dword:00000001" ? .enabled : .setOtherwise
    }

    /// A `.reg` that sets the value and leaves the key's other values alone.
    static let registryDocument = [
        "Windows Registry Editor Version 5.00",
        "",
        "[\(registryKey)]",
        "\"\(valueName)\"=dword:00000001",
        ""
    ].joined(separator: "\r\n")
}

extension Wine {
    /// Analyses the program a launch starts, without running it, and gives
    /// the bottle what that kind of program needs (see ``Sommelier``).
    ///
    /// Runs on every launch: the analysis reads a few kilobytes of the
    /// executable, fonts are copied only while missing, and the registry is
    /// written only while the WPF value is unset. It never fails a launch; a
    /// file that can't be analysed gets no advice.
    ///
    /// - Parameters:
    ///   - url: The executable being launched.
    ///   - bottle: The bottle it launches in.
    ///   - d3dMetalAvailable: Whether the runtime serves Direct3D 12 through D3DMetal.
    ///   - importer: What imports registry documents into the bottle.
    /// - Returns: The advice, with notes for what was done or found.
    @MainActor
    static func applySommelier(
        for url: URL,
        bottle: Bottle,
        d3dMetalAvailable: Bool,
        importer: RegistryImporter
    ) async -> SommelierAdvice {
        let bottleURL = bottle.url
        let (analyzed, wpfState) = await Task.detached(priority: .userInitiated) {
            () -> (SommelierAdvice?, WPFSoftwareRendering.State) in
            guard let analysis = try? ExecutableAnalyzer.analyze(url: url) else {
                return (nil, .unknown)
            }
            let advice = Sommelier.advice(for: analysis, d3dMetalAvailable: d3dMetalAvailable)
            if advice.installCoreFonts {
                BottleFontBootstrap.copyCoreFonts(toPrefix: bottleURL)
            }
            let state = advice.softwareRenderWPF ? WPFSoftwareRendering.state(bottleURL: bottleURL) : .unknown
            return (advice, state)
        }.value

        guard var advice = analyzed else {
            return SommelierAdvice()
        }

        if advice.softwareRenderWPF {
            var enabled = wpfState == .enabled
            if wpfState == .missing {
                do {
                    try await importer(WPFSoftwareRendering.registryDocument, bottle)
                    enabled = true
                } catch {
                    logger.error("Failed to enable WPF software rendering: \(error.localizedDescription)")
                }
            }
            if !enabled {
                // The note says software rendering is on; don't claim what didn't happen.
                advice.notes.removeAll { $0 == .wpfSoftwareRendering }
            }
        }

        for note in advice.notes {
            logger.info("\(url.lastPathComponent, privacy: .public): \(note.logLine, privacy: .public)")
        }
        return advice
    }
}

extension FileHandle {
    /// Writes a launch's Sommelier notes under the run log header, one
    /// `Sommelier:` line each, so a log shows what was applied and why.
    func writeSommelierNotes(_ notes: [String]) {
        guard !notes.isEmpty else { return }
        writeWineLog(line: notes.map { "Sommelier: \($0)\n" }.joined() + "\n")
    }
}
