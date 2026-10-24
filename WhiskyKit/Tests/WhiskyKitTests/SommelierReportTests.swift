//
//  SommelierReportTests.swift
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

@Suite("Sommelier reports")
struct SommelierReportTests {
    private let bottleURL: URL

    init() throws {
        bottleURL = FileManager.default.temporaryDirectory.appending(path: "SommelierReportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: bottleURL.appending(path: "drive_c"), withIntermediateDirectories: true
        )
    }

    private func write(_ executable: SyntheticPE, at relativePath: String) throws -> URL {
        let url = bottleURL.appending(path: "drive_c").appending(path: relativePath)
        try executable.write(to: url)
        return url
    }

    // MARK: - Product name

    @Test("The product name comes from the version resource")
    func productName() throws {
        var launcher = SyntheticPE.wpfApp
        launcher.versionStrings = [
            "ProductName": "Magic Wings", "FileDescription": "MagicWings.Launcher", "CompanyName": "Juice Games"
        ]
        let url = try write(launcher, at: "Launcher/MagicWings.Launcher.exe")

        let analysis = try ExecutableAnalyzer.analyze(url: url)

        #expect(analysis.productName == "Magic Wings")
        #expect(analysis.versionStrings["CompanyName"] == "Juice Games")
        // The .NET metadata is read as before, next to the resources.
        #expect(analysis.usesWPF)
    }

    @Test("Without a product name, the file description names the program")
    func fileDescriptionFallback() throws {
        var tool = SyntheticPE(imports: ["kernel32.dll"])
        tool.versionStrings = ["FileDescription": "Map Editor"]
        let url = try write(tool, at: "Tools/editor.exe")

        #expect(try ExecutableAnalyzer.analyze(url: url).productName == "Map Editor")
    }

    @Test("A program without a version resource has no product name")
    func noVersionResource() throws {
        let url = try write(.direct3D11Game, at: "Game/Game.exe")
        #expect(try ExecutableAnalyzer.analyze(url: url).productName == nil)
    }

    @Test("A malformed version block yields nothing instead of crashing")
    func malformedVersionInfo() {
        let valid = SyntheticVersionInfo.build(["ProductName": "Game"])
        #expect(PortableExecutableReader.versionStrings(inVersionInfo: valid) == ["ProductName": "Game"])
        for length in stride(from: 0, to: valid.count, by: 7) {
            _ = PortableExecutableReader.versionStrings(inVersionInfo: valid.prefix(length))
        }
        var lying = valid
        lying[0] = 0xFF
        lying[1] = 0xFF // a length past the end
        #expect(PortableExecutableReader.versionStrings(inVersionInfo: lying).isEmpty)
    }

    // MARK: - Report and badges

    @Test("A report is made once and kept until the executable changes")
    func reportIsCached() throws {
        let url = try write(.wpfApp, at: "Tool/Tool.exe")

        let first = try #require(SommelierReportStore.report(for: url, bottleURL: bottleURL))
        #expect(first.usesWPF)
        #expect(SommelierReportStore.load(bottleURL: bottleURL)["tool/tool.exe"] == first)

        // Same size and date: the stored report is returned, not a new analysis.
        try SyntheticPE(imports: ["kernel32.dll"]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: first.modified], ofItemAtPath: url.path)
        let sameStamp = SommelierReportStore.report(for: url, bottleURL: bottleURL)
        if try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 == first.fileSize {
            #expect(sameStamp == first)
        }

        // A newer file is analysed again.
        try FileManager.default.setAttributes(
            [.modificationDate: first.modified.addingTimeInterval(60)], ofItemAtPath: url.path
        )
        let updated = try #require(SommelierReportStore.report(for: url, bottleURL: bottleURL))
        #expect(!updated.usesWPF)
    }

    @Test("Files that aren't programs get no report")
    func noReportForNonPrograms() throws {
        let url = bottleURL.appending(path: "drive_c/readme.exe")
        try Data("MZ".utf8).write(to: url)
        #expect(SommelierReportStore.report(for: url, bottleURL: bottleURL) == nil)
        #expect(SommelierReportStore.report(for: bottleURL.appending(path: "missing.exe"), bottleURL: bottleURL) == nil)
    }

    @Test("A launch is recorded, and only notes the previous launch didn't have are announced")
    func recordLaunch() throws {
        let url = try write(.wpfApp, at: "Tool/Tool.exe")
        let analysis = try ExecutableAnalyzer.analyze(url: url)
        let detected = SommelierNote.detected(engine: nil, api: nil, dotNetRuntime: "v4.0.30319")

        let first = SommelierReportStore.recordLaunch(
            of: url, bottleURL: bottleURL, analysis: analysis, notes: [detected, .wpfSoftwareRendering]
        )
        #expect(first == [.wpfSoftwareRendering])

        let second = SommelierReportStore.recordLaunch(
            of: url, bottleURL: bottleURL, analysis: analysis, notes: [detected, .wpfSoftwareRendering]
        )
        #expect(second.isEmpty)

        let report = try #require(SommelierReportStore.report(for: url, bottleURL: bottleURL))
        #expect(report.lastLaunch != nil)
        #expect(report.lastLaunchNotes == [detected, .wpfSoftwareRendering])
    }

    @Test("Reports survive a round trip through the property list")
    func codable() throws {
        let url = try write(.chromiumShell, at: "Atlas/Atlas.exe")
        let analysis = try ExecutableAnalyzer.analyze(url: url)
        SommelierReportStore.recordLaunch(
            of: url, bottleURL: bottleURL, analysis: analysis,
            notes: [.antiCheat(.easyAntiCheat), .detected(engine: .unity, api: .direct3D11, dotNetRuntime: nil)]
        )
        let loaded = try #require(SommelierReportStore.load(bottleURL: bottleURL)["atlas/atlas.exe"])
        #expect(loaded.lastLaunchNotes.count == 2)
        #expect(loaded.lastLaunchNotes.first == .antiCheat(.easyAntiCheat))
    }

    @Test("Recipes and badges follow what the program is")
    func recipesAndBadges() throws {
        func report(_ change: (inout ExecutableAnalysis) -> Void) -> SommelierReport {
            var analysis = ExecutableAnalysis(url: bottleURL)
            change(&analysis)
            return SommelierReport(analysis: analysis, fileSize: 1, modified: .now)
        }

        let wpf = report { $0.referencedAssemblies = ["PresentationFramework"]
            $0.dotNetRuntimeVersion = "v4"
        }
        #expect(wpf.recipes == [.wpfSoftwareRendering, .coreFonts])
        #expect(wpf.badge(d3dMetalAvailable: false) == .autoAdjusted)

        let electron = report { $0.isChromiumApp = true
            $0.delayLoadedLibraries = ["d3d12.dll"]
        }
        #expect(electron.recipes == [.chromiumOnDXVK])
        #expect(electron.graphicsAPI == nil)
        #expect(electron.badge(d3dMetalAvailable: false) == .autoAdjusted)

        let direct3D12 = report { $0.importedLibraries = ["d3d12.dll"] }
        #expect(direct3D12.badge(d3dMetalAvailable: false) == .needsD3DMetal)
        #expect(direct3D12.badge(d3dMetalAvailable: true) == nil)

        // An anti-cheat outranks everything else on the card.
        let protected = report { $0.importedLibraries = ["d3d12.dll"]
            $0.antiCheats = [.battlEye]
        }
        #expect(protected.badge(d3dMetalAvailable: false) == .antiCheat)

        let plain = report { $0.importedLibraries = ["d3d11.dll"] }
        #expect(plain.badge(d3dMetalAvailable: false) == nil)
    }

    @Test("Keys are relative to drive_c and lowercased, so a moved bottle keeps its reports")
    func keys() {
        let url = bottleURL.appending(path: "drive_c/Program Files/Game/Game.EXE")
        #expect(SommelierReportStore.key(for: url, bottleURL: bottleURL) == "program files/game/game.exe")
    }
}
