//
//  InstallModel.swift
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

import Foundation
import WhiskyKit

/// Takes an installer from a file to a game in the library: what the Sommelier
/// makes of it, a bottle of its own (or an existing one), the installer run in
/// it, and the program it leaves behind.
@MainActor
final class InstallModel: ObservableObject {
    enum Phase: Equatable {
        case choosing
        case ready
        /// A new bottle is being made for the installer.
        case preparing
        /// The installer is running; the game appears when its shortcut does.
        case installing
        case done(programName: String)
        case failed(message: String)
    }

    /// Where the installer runs.
    enum Destination: Hashable {
        case newBottle
        case bottle(URL)
    }

    /// What the Sommelier found in the chosen installer, as lines to show.
    struct Finding: Hashable {
        let text: String
        let isWarning: Bool
    }

    /// The chosen installer and what the Sommelier made of it.
    struct Choice: Equatable {
        let url: URL
        let productName: String?
        let company: String?
        /// `nil` when the file couldn't be analysed, as with an `.msi`.
        let findings: [Finding]?
    }

    @Published var phase: Phase = .choosing
    @Published private(set) var choice: Choice?
    @Published var destination: Destination = .newBottle
    @Published var newBottleName = ""

    /// The file extensions Alcool installs from.
    static let extensions: Set<String> = ["exe", "msi", "bat", "msix", "appx"]

    func choose(_ url: URL) async {
        guard Self.extensions.contains(url.pathExtension.lowercased()) else {
            phase = .failed(message: String(localized: "install.unsupported"))
            return
        }
        let analysis = await Task.detached(priority: .userInitiated) {
            try? ExecutableAnalyzer.analyze(url: url)
        }.value
        choice = Choice(
            url: url,
            productName: analysis?.productName,
            company: analysis?.versionStrings["CompanyName"],
            findings: analysis.map(Self.findings(for:))
        )
        newBottleName = InstallerNaming.bottleName(forInstaller: url, productName: analysis?.productName)
            ?? String(localized: "install.defaultName")
        destination = .newBottle
        phase = .ready
    }

    func reset() {
        choice = nil
        phase = .choosing
    }

    func install() async {
        guard let choice else { return }
        let bottle: Bottle
        switch destination {
        case let .bottle(url):
            guard let existing = BottleVM.shared.bottles.first(where: { $0.url == url }) else {
                phase = .failed(message: String(localized: "install.failed.bottle"))
                return
            }
            bottle = existing
        case .newBottle:
            phase = .preparing
            let location = UserDefaults.standard.url(forKey: "defaultBottleLocation") ?? BottleData.defaultBottleDir
            let name = newBottleName.trimmingCharacters(in: .whitespaces).isEmpty
                ? String(localized: "install.defaultName") : newBottleName
            let url = BottleVM.shared.createNewBottle(bottleName: name, winVersion: .win10, bottleURL: location)
            guard let created = await bottleWhenReady(at: url) else {
                phase = .failed(message: String(localized: "install.failed.bottle"))
                return
            }
            bottle = created
        }

        phase = .installing
        let pinsBefore = Set(bottle.settings.pins.compactMap(\.url))
        let result = await InstallerLauncher.run(choice.url, in: bottle)
        if result.style == .error {
            phase = .failed(message: result.message)
            return
        }
        await waitForInstalledProgram(in: bottle, pinsBefore: pinsBefore)
    }

    // MARK: - Waiting

    /// The bottle being made at `url`, once it's ready; `nil` if making it
    /// failed (it leaves the list) or took longer than five minutes.
    private func bottleWhenReady(at url: URL) async -> Bottle? {
        var seen = false
        for _ in 0 ..< 600 {
            if let bottle = BottleVM.shared.bottles.first(where: { $0.url == url }) {
                seen = true
                if !bottle.inFlight, bottle.isAvailable {
                    return bottle
                }
            } else if seen {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// Waits, for up to an hour, for the program the installer adds: its
    /// shortcut is pinned by ``MacShortcutSync`` within seconds of being
    /// written. `wine start` returns as soon as the installer opens, so this is
    /// how the installer's end is seen.
    private func waitForInstalledProgram(in bottle: Bottle, pinsBefore: Set<URL>) async {
        for _ in 0 ..< 1_800 {
            guard phase == .installing else { return }
            if let pin = bottle.settings.pins.first(where: { $0.url.map { !pinsBefore.contains($0) } ?? false }) {
                phase = .done(programName: pin.name)
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - Findings

    private static func findings(for analysis: ExecutableAnalysis) -> [Finding] {
        var findings: [Finding] = []
        if analysis.usesWPF {
            findings.append(Finding(text: SommelierRecipe.wpfSoftwareRendering.title, isWarning: false))
        }
        if analysis.usesWPF || analysis.usesWinForms {
            findings.append(Finding(text: SommelierRecipe.coreFonts.title, isWarning: false))
        }
        if analysis.isChromiumApp {
            findings.append(Finding(text: SommelierRecipe.chromiumOnDXVK.title, isWarning: false))
        }
        for cheat in analysis.antiCheats.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let message = SommelierNote.antiCheat(cheat).message {
                findings.append(Finding(text: message, isWarning: true))
            }
        }
        if analysis.antiCheats.isEmpty {
            findings.append(Finding(text: String(localized: "install.noAntiCheat"), isWarning: false))
        }
        return findings
    }
}
