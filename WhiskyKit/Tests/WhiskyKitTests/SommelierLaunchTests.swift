//
//  SommelierLaunchTests.swift
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

/// Records the registry documents a launch imports and the overrides it writes.
@MainActor
private final class SommelierRegistryRecorder {
    private(set) var imports: [String] = []
    private(set) var writes: [[(scope: Wine.DLLOverrideScope, overrides: String)]] = []
    var failImports = false

    var importer: Wine.RegistryImporter {
        { document, _ in
            if self.failImports {
                throw CocoaError(.fileWriteUnknown)
            }
            self.imports.append(document)
        }
    }

    var writer: Wine.DLLOverrideWriter {
        { _, scopes in self.writes.append(scopes) }
    }

    func overrides(for scope: Wine.DLLOverrideScope) -> [String: String]? {
        guard writes.count == 1, let entry = writes[0].first(where: { $0.scope == scope }) else {
            return nil
        }
        return Wine.parseDLLOverrides(entry.overrides)
    }
}

@Suite("Sommelier launches")
@MainActor
final class SommelierLaunchTests {
    private let tempRoot: URL

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory.appending(path: "sommelier_launch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// A bottle that leaves the backend to Alcool, with a user hive that may
    /// already hold the WPF value.
    private func makeBottle(wpfValue: String? = nil) throws -> Bottle {
        let bottleURL = tempRoot.appending(path: "Bottle")
        try FileManager.default.createDirectory(
            at: bottleURL.appending(path: "drive_c/windows/system32"), withIntermediateDirectories: true
        )
        var userReg = "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1788028200\n\"Version\"=\"win10\"\n\n"
        if let wpfValue {
            userReg += "[Software\\\\Microsoft\\\\Avalon.Graphics] 1788028200\n"
            userReg += "\"DisableHWAcceleration\"=\(wpfValue)\n\n"
        }
        try userReg.write(to: bottleURL.appending(path: "user.reg"), atomically: true, encoding: .utf8)
        let bottle = Bottle(bottleUrl: bottleURL)
        bottle.settings.graphicsBackend = .recommended
        return bottle
    }

    private func prepare(
        _ url: URL, in bottle: Bottle, recorder: SommelierRegistryRecorder
    ) async throws -> Wine.PreparedLaunch {
        try await Wine.prepareProgramLaunch(
            at: url, bottle: bottle,
            recommendedBackend: .d3dMetal, builtinD3D12IsD3DMetal: true,
            overrideWriter: recorder.writer, importer: recorder.importer
        )
    }

    @Test("Launching a WPF app turns WPF hardware acceleration off once, and says so in the log")
    func wpfLaunch() async throws {
        let bottle = try makeBottle()
        let app = bottle.url.appending(path: "drive_c/Program Files/Tool/Tool.exe")
        try SyntheticPE.wpfApp.write(to: app)
        let recorder = SommelierRegistryRecorder()

        let launch = try await prepare(app, in: bottle, recorder: recorder)

        #expect(recorder.imports == [WPFSoftwareRendering.registryDocument])
        #expect(launch.sommelierNotes.contains(SommelierNote.wpfSoftwareRendering.logLine))
    }

    @Test("A bottle that already renders WPF in software isn't written to again")
    func wpfAlreadyEnabled() async throws {
        let bottle = try makeBottle(wpfValue: "dword:00000001")
        let app = bottle.url.appending(path: "drive_c/Program Files/Tool/Tool.exe")
        try SyntheticPE.wpfApp.write(to: app)
        let recorder = SommelierRegistryRecorder()

        let launch = try await prepare(app, in: bottle, recorder: recorder)

        #expect(recorder.imports.isEmpty)
        #expect(launch.sommelierNotes.contains(SommelierNote.wpfSoftwareRendering.logLine))
    }

    @Test("A WPF value someone set is left alone, and the log doesn't claim software rendering")
    func wpfSetOtherwise() async throws {
        let bottle = try makeBottle(wpfValue: "dword:00000000")
        let app = bottle.url.appending(path: "drive_c/Program Files/Tool/Tool.exe")
        try SyntheticPE.wpfApp.write(to: app)
        let recorder = SommelierRegistryRecorder()

        let launch = try await prepare(app, in: bottle, recorder: recorder)

        #expect(recorder.imports.isEmpty)
        #expect(!launch.sommelierNotes.contains(SommelierNote.wpfSoftwareRendering.logLine))
    }

    @Test("A failed import doesn't fail the launch, and the log doesn't claim software rendering")
    func wpfImportFails() async throws {
        let bottle = try makeBottle()
        let app = bottle.url.appending(path: "drive_c/Program Files/Tool/Tool.exe")
        try SyntheticPE.wpfApp.write(to: app)
        let recorder = SommelierRegistryRecorder()
        recorder.failImports = true

        let launch = try await prepare(app, in: bottle, recorder: recorder)

        #expect(!launch.sommelierNotes.contains(SommelierNote.wpfSoftwareRendering.logLine))
    }

    @Test("An Electron app the launcher list doesn't know runs on DXVK")
    func electronLaunch() async throws {
        let bottle = try makeBottle()
        let folder = bottle.url.appending(path: "drive_c/users/crossover/AppData/Local/Atlas")
        let app = folder.appending(path: "Atlas.exe")
        try SyntheticPE.chromiumShell.write(to: app)
        try Data([0]).write(to: folder.appending(path: "icudtl.dat"))
        try Data([0]).write(to: folder.appending(path: "resources.pak"))
        let recorder = SommelierRegistryRecorder()

        let launch = try await prepare(app, in: bottle, recorder: recorder)

        #expect(launch.sommelierNotes.contains(SommelierNote.chromiumUsesDXVK.logLine))
        // D3DMetal, the bottle's backend here, runs on Wine's builtin d3d9; DXVK
        // brings its own.
        #expect(recorder.overrides(for: .program("Atlas.exe"))?["d3d9"] == "n,b")
    }

    @Test("The same program without Chromium's files keeps the bottle's backend")
    func nativeLaunchKeepsBackend() async throws {
        let bottle = try makeBottle()
        let app = bottle.url.appending(path: "drive_c/users/crossover/AppData/Local/Atlas/Atlas.exe")
        try SyntheticPE.chromiumShell.write(to: app)
        let recorder = SommelierRegistryRecorder()

        let launch = try await prepare(app, in: bottle, recorder: recorder)

        // Still analysed (it loads Direct3D on demand), but not taken for a Chromium shell.
        #expect(!launch.sommelierNotes.contains(SommelierNote.chromiumUsesDXVK.logLine))
        #expect(recorder.overrides(for: .program("Atlas.exe"))?["d3d9"] != "n,b")
    }

    @Test("A bottle set to a backend keeps it for an Electron app")
    func explicitBackendWins() async throws {
        let bottle = try makeBottle()
        bottle.settings.graphicsBackend = .wined3d
        let folder = bottle.url.appending(path: "drive_c/Atlas")
        let app = folder.appending(path: "Atlas.exe")
        try SyntheticPE.chromiumShell.write(to: app)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "resources"),
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: folder.appending(path: "resources/app.asar"))
        let recorder = SommelierRegistryRecorder()

        let launch = try await prepare(app, in: bottle, recorder: recorder)

        #expect(recorder.overrides(for: .program("Atlas.exe"))?["d3d9"] != "n,b")
        // DXVK wasn't applied, so neither the log nor an announcement says it was.
        #expect(!launch.sommelierNotes.contains(SommelierNote.chromiumUsesDXVK.logLine))
    }

    @Test("A program's first launch with an adjustment is announced, and the next one isn't")
    func firstAdjustmentIsAnnounced() async throws {
        let bottle = try makeBottle()
        let app = bottle.url.appending(path: "drive_c/Program Files/Tool/Tool.exe")
        try SyntheticPE.wpfApp.write(to: app)
        let collector = AnnouncementCollector(bottleURL: bottle.url)
        defer { collector.stop() }
        let recorder = SommelierRegistryRecorder()

        _ = try await prepare(app, in: bottle, recorder: recorder)
        _ = try await prepare(app, in: bottle, recorder: recorder)

        #expect(collector.announcements.count == 1)
        #expect(collector.announcements.first?.notes == [.wpfSoftwareRendering])
        let report = SommelierReportStore.load(bottleURL: bottle.url)["program files/tool/tool.exe"]
        #expect(report?.lastLaunch != nil)
    }
}

/// Collects the Sommelier announcements for one bottle, since tests in other
/// suites may launch at the same time.
@MainActor
private final class AnnouncementCollector {
    private(set) var announcements: [SommelierAnnouncement] = []
    private var token: NSObjectProtocol?

    init(bottleURL: URL) {
        token = NotificationCenter.default.addObserver(
            forName: .sommelierDidAnnounce, object: nil, queue: nil
        ) { [weak self] notification in
            guard let announcement = notification.object as? SommelierAnnouncement,
                  announcement.bottleURL == bottleURL
            else { return }
            // Posted on the main actor, and delivered on the posting thread.
            MainActor.assumeIsolated {
                self?.announcements.append(announcement)
            }
        }
    }

    func stop() {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
