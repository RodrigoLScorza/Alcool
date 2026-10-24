//
//  InstallerLauncher.swift
//  Whisky
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

import AppKit
import UniformTypeIdentifiers
import WhiskyKit

/// Asks for a Windows installer or program and runs it in a bottle: what the
/// library's "Install game" does. The program an installer leaves behind
/// reaches the library through its shortcuts (see ``MacShortcutSync``).
@MainActor
enum InstallerLauncher {
    /// The files a person can pick: what the bottle's Run button accepts.
    static let contentTypes: [UTType] = [
        UTType.exe,
        UTType(exportedAs: "com.microsoft.msi-installer"),
        UTType(exportedAs: "com.microsoft.bat"),
        UTType(exportedAs: "com.microsoft.msix-package"),
        UTType(exportedAs: "com.microsoft.appx-package")
    ]

    /// Asks for an installer, starting in Downloads, where one usually is.
    ///
    /// - Returns: The chosen file, or `nil` when the panel was cancelled.
    static func chooseInstaller() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = contentTypes
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.urls.first : nil
    }

    /// Runs `url` in `bottle` the way the bottle's Run button does, and says
    /// how it went.
    ///
    /// Returns when the installer exits, which for an installer is when the
    /// person has finished with it.
    static func run(_ url: URL, in bottle: Bottle) async -> ToastData {
        // Settings have to be in place before Wine.runProgram reads them.
        LauncherFixes.detectAndApply(from: url, for: bottle)
        Telemetry.capture(.firstProgramLaunchAttempted)
        do {
            if url.pathExtension.lowercased() == "bat" {
                try await Wine.runBatchFile(url: url, bottle: bottle)
            } else {
                try await Wine.runProgram(at: url, bottle: bottle)
            }
            return ToastData(message: String(localized: "status.launched \(url.lastPathComponent)"), style: .success)
        } catch {
            return ToastData(
                message: String(localized: "status.launchFailed \(error.localizedDescription)"),
                style: .error,
                autoDismiss: false
            )
        }
    }
}
