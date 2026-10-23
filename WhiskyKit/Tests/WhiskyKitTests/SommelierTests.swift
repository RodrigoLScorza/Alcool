//
//  SommelierTests.swift
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

@Suite("Sommelier")
struct SommelierTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "SommelierTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func touch(_ relativePath: String) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: url)
    }

    private func folder(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: root.appending(path: relativePath),
            withIntermediateDirectories: true
        )
    }

    private func analyze(_ executable: SyntheticPE, at relativePath: String) throws -> ExecutableAnalysis {
        let url = root.appending(path: relativePath)
        try executable.write(to: url)
        return try ExecutableAnalyzer.analyze(url: url)
    }

    // MARK: - Reader

    @Test("The reader returns the machine, imports and delay-loaded imports")
    func readsNativeImports() throws {
        let url = root.appending(path: "Game.exe")
        try SyntheticPE.direct3D11Game.write(to: url)

        let facts = try PortableExecutableReader.read(url: url)

        #expect(facts.machine == .x64)
        #expect(facts.importedLibraries == ["kernel32.dll", "d3d11.dll", "dxgi.dll", "d3d9.dll"])
        #expect(facts.delayLoadedLibraries == ["d3d12.dll"])
        #expect(facts.dotNetRuntimeVersion == nil)
    }

    @Test("The reader returns the .NET runtime and the UI assemblies in the #Strings heap")
    func readsDotNetMetadata() throws {
        let url = root.appending(path: "Launcher.exe")
        try SyntheticPE.wpfApp.write(to: url)

        let facts = try PortableExecutableReader.read(url: url)

        #expect(facts.machine == .x86)
        #expect(facts.dotNetRuntimeVersion == "v4.0.30319")
        // Only whole entries count; MainWindow and <Module> are not assemblies it looks for.
        #expect(facts.referencedAssemblies == ["PresentationFramework", "WindowsBase"])
    }

    @Test("A heap entry that only contains an assembly name is not that assembly")
    func partialHeapEntriesDontMatch() {
        let heap = Data("\0MyPresentationFrameworkHelper\0System.Windows.Forms.Design\0".utf8)
        #expect(PortableExecutableReader.knownAssemblies(inStringsHeap: heap).isEmpty)
    }

    @Test("Files that aren't PE executables are rejected", arguments: [
        Data("MZ".utf8), Data(), Data("#!/bin/sh\n".utf8), Data([0x4D, 0x5A] + [UInt8](repeating: 0xFF, count: 0x80))
    ])
    func rejectsNonPE(contents: Data) throws {
        let url = root.appending(path: "NotAProgram.exe")
        try contents.write(to: url)
        #expect(throws: (any Error).self) {
            try PortableExecutableReader.read(url: url)
        }
    }

    @Test("A truncated file doesn't crash the reader")
    func truncatedFile() throws {
        let full = SyntheticPE.wpfApp.data()
        for length in stride(from: 0x40, to: full.count, by: 37) {
            let url = root.appending(path: "Truncated-\(length).exe")
            try full.prefix(length).write(to: url)
            _ = try? PortableExecutableReader.read(url: url)
        }
    }

    // MARK: - Analysis and advice

    @Test("A WPF app renders in software and gets the core fonts")
    func wpfAdvice() throws {
        let analysis = try analyze(.wpfApp, at: "users/me/AppData/Local/Tool/Tool.exe")
        let advice = Sommelier.advice(for: analysis, d3dMetalAvailable: false)

        #expect(analysis.usesWPF)
        #expect(advice.softwareRenderWPF)
        #expect(advice.installCoreFonts)
        #expect(advice.preferredBackend == nil)
        #expect(advice.notes.contains(.wpfSoftwareRendering))
        #expect(advice.notes.contains(.detected(engine: nil, api: nil, dotNetRuntime: "v4.0.30319")))
    }

    @Test("A WinForms app gets the core fonts, and keeps hardware rendering")
    func winFormsAdvice() throws {
        let analysis = try analyze(.winFormsApp, at: "Tools/Editor.exe")
        let advice = Sommelier.advice(for: analysis, d3dMetalAvailable: false)

        #expect(advice.installCoreFonts)
        #expect(!advice.softwareRenderWPF)
    }

    @Test("A Velopack stub is analysed through the program it starts")
    func velopackStub() throws {
        try SyntheticPE.wpfApp.write(to: root.appending(path: "App/current/App.exe"))
        let analysis = try analyze(SyntheticPE(imports: ["kernel32.dll"]), at: "App/App.exe")

        #expect(analysis.url.lastPathComponent == "App.exe")
        #expect(analysis.url.deletingLastPathComponent().lastPathComponent == "current")
        #expect(analysis.usesWPF)
    }

    @Test("An Electron app is steered to DXVK and its renderer isn't named")
    func electronAdvice() throws {
        try touch("Launcher/resources/app.asar")
        let analysis = try analyze(.chromiumShell, at: "Launcher/Launcher.exe")
        let advice = Sommelier.advice(for: analysis, d3dMetalAvailable: false)

        #expect(analysis.isChromiumApp)
        #expect(advice.preferredBackend == .dxvk)
        #expect(advice.notes.contains(.chromiumUsesDXVK))
        // Chromium delay-loads d3d12; that isn't a Direct3D 12 program.
        #expect(!advice.notes.contains(.direct3D12WithoutD3DMetal))
        #expect(!advice.notes.contains { if case .detected = $0 { true } else { false } })
    }

    @Test("A CEF shell is recognised from the Chromium runtime files")
    func cefAdvice() throws {
        try touch("Store/icudtl.dat")
        try touch("Store/resources.pak")
        let analysis = try analyze(.chromiumShell, at: "Store/Store.exe")

        #expect(analysis.isChromiumApp)
    }

    @Test("A game with an in-game browser stays a game")
    func gameWithEmbeddedCEF() throws {
        try touch("Game/icudtl.dat")
        try touch("Game/chrome_100_percent.pak")
        let analysis = try analyze(.direct3D11Game, at: "Game/Game.exe")
        let advice = Sommelier.advice(for: analysis, d3dMetalAvailable: false)

        #expect(!analysis.isChromiumApp)
        #expect(advice.preferredBackend == nil)
    }

    @Test("A Unity game is recognised from its data folder, and UnityPlayer.dll names its renderer")
    func unityGame() throws {
        try folder("Unity/MyGame_Data")
        try SyntheticPE.direct3D11Game.write(to: root.appending(path: "Unity/UnityPlayer.dll"))
        let analysis = try analyze(SyntheticPE(imports: ["kernel32.dll", "unityplayer.dll"]), at: "Unity/MyGame.exe")

        #expect(analysis.engine == .unity)
        #expect(analysis.primaryGraphicsAPI == .direct3D11)
    }

    @Test("UnityPlayer.dll without a data folder is no Unity game")
    func launcherNextToUnityPlayer() throws {
        try SyntheticPE.direct3D11Game.write(to: root.appending(path: "Shared/UnityPlayer.dll"))
        let analysis = try analyze(.wpfApp, at: "Shared/Launcher.exe")

        #expect(analysis.engine == nil)
    }

    @Test("An Unreal game is recognised from its Binaries layout")
    func unrealGame() throws {
        try folder("Seria/Engine")
        let analysis = try analyze(.direct3D11Game, at: "Seria/Seria/Binaries/Win64/Seria.exe")

        #expect(analysis.engine == .unreal)
        // Unreal imports d3d9 for helpers; the newest Direct3D at startup is the renderer.
        #expect(analysis.primaryGraphicsAPI == .direct3D11)
    }

    @Test("Direct3D 12 at startup warns only without D3DMetal")
    func direct3D12Warning() throws {
        let analysis = try analyze(SyntheticPE(imports: ["d3d12.dll", "dxgi.dll"]), at: "D3D12/Game.exe")

        let without = Sommelier.advice(for: analysis, d3dMetalAvailable: false)
        let with = Sommelier.advice(for: analysis, d3dMetalAvailable: true)

        #expect(without.notes.contains(.direct3D12WithoutD3DMetal))
        #expect(!with.notes.contains(.direct3D12WithoutD3DMetal))
    }

    @Test("Direct3D 9 programs get a note about the OpenGL path")
    func direct3D9Note() throws {
        let analysis = try analyze(SyntheticPE(imports: ["d3d9.dll"]), at: "Old/Game.exe")
        let advice = Sommelier.advice(for: analysis, d3dMetalAvailable: true)

        #expect(advice.notes.contains(.direct3D9OnOpenGL))
    }

    @Test("An anti-cheat next to the game, or one folder up, is reported")
    func antiCheatFound() throws {
        try folder("Arena/EasyAntiCheat")
        try touch("Arena/bin/BEClient_x64.dll")
        let analysis = try analyze(.direct3D11Game, at: "Arena/bin/Arena.exe")
        let advice = Sommelier.advice(for: analysis, d3dMetalAvailable: false)

        #expect(analysis.antiCheats == [.easyAntiCheat, .battlEye])
        #expect(advice.notes.contains(.antiCheat(.easyAntiCheat)))
        #expect(advice.notes.contains(.antiCheat(.battlEye)))
    }

    @Test("Windows' own Easy Anti-Cheat service folder isn't any one game's")
    func antiCheatInSharedFolder() throws {
        try folder("Program Files (x86)/EasyAntiCheat")
        let analysis = try analyze(.direct3D11Game, at: "Program Files (x86)/Puzzle/Puzzle.exe")

        #expect(analysis.antiCheats.isEmpty)
    }

    @Test("A native program with nothing to recognise gets no advice")
    func plainProgram() throws {
        let analysis = try analyze(SyntheticPE(imports: ["kernel32.dll", "user32.dll"]), at: "Tools/Tool.exe")
        #expect(Sommelier.advice(for: analysis, d3dMetalAvailable: false) == SommelierAdvice())
    }
}
