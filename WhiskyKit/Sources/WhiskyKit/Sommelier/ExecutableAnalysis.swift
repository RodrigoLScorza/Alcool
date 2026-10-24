//
//  ExecutableAnalysis.swift
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

/// A graphics API an executable links against, ordered from least to most capable.
public enum GraphicsAPI: Int, Codable, Sendable, Comparable, CaseIterable {
    case openGL
    case vulkan
    case direct3D9
    case direct3D10
    case direct3D11
    case direct3D12

    public static func < (lhs: GraphicsAPI, rhs: GraphicsAPI) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The API a DLL import stands for, if it is a graphics runtime.
    static func api(forImport library: String) -> GraphicsAPI? {
        switch library {
        case "d3d9.dll": .direct3D9
        case "d3d10.dll", "d3d10_1.dll", "d3d10core.dll": .direct3D10
        case "d3d11.dll": .direct3D11
        case "d3d12.dll": .direct3D12
        case "vulkan-1.dll": .vulkan
        case "opengl32.dll": .openGL
        default: nil
        }
    }

    public var displayName: String {
        switch self {
        case .openGL: "OpenGL"
        case .vulkan: "Vulkan"
        case .direct3D9: "Direct3D 9"
        case .direct3D10: "Direct3D 10"
        case .direct3D11: "Direct3D 11"
        case .direct3D12: "Direct3D 12"
        }
    }
}

/// A game engine recognised from the files it ships next to the executable.
public enum GameEngine: String, Codable, Sendable {
    case unity
    case unreal
    case godot
    case gameMaker

    public var displayName: String {
        switch self {
        case .unity: "Unity"
        case .unreal: "Unreal Engine"
        case .godot: "Godot"
        case .gameMaker: "GameMaker"
        }
    }
}

/// A kernel- or service-level anti-cheat recognised from the files it installs
/// next to a game. Most refuse to run under Wine on macOS.
public enum AntiCheat: String, Codable, Sendable, CaseIterable {
    case easyAntiCheat
    case battlEye
    case xigncode
    case gameGuard
    case punkBuster
    case antiCheatExpert

    public var displayName: String {
        switch self {
        case .easyAntiCheat: "Easy Anti-Cheat"
        case .battlEye: "BattlEye"
        case .xigncode: "XIGNCODE3"
        case .gameGuard: "nProtect GameGuard"
        case .punkBuster: "PunkBuster"
        case .antiCheatExpert: "Anti-Cheat Expert"
        }
    }

    /// Whether a lowercased file or folder name in a game folder belongs to this anti-cheat.
    func matches(_ name: String) -> Bool {
        switch self {
        case .easyAntiCheat:
            name.hasPrefix("easyanticheat") || name == "start_protected_game.exe"
        case .battlEye:
            name == "battleye" || name.hasPrefix("beservice") || name.hasPrefix("beclient")
        case .xigncode:
            name == "xigncode" || name == "xigncode3" || name.hasSuffix(".xem")
        case .gameGuard:
            name == "gameguard" || name == "gamemon.des" || name == "gameguard.des"
        case .punkBuster:
            name == "pbsvc.exe" || name.hasPrefix("pnkbstr")
        case .antiCheatExpert:
            name == "anticheatexpert" || name.hasPrefix("ace-base") || name.hasPrefix("sguard")
        }
    }
}

/// What the Sommelier learned about an executable without running it.
public struct ExecutableAnalysis: Equatable, Sendable {
    /// The file that was analysed. For an installer stub that only starts
    /// the real program, this is the real program.
    public var url: URL
    public var machine: ExecutableMachine = .unknown
    /// DLLs loaded at startup, lowercased, including those of the engine
    /// runtime next to the executable (such as `UnityPlayer.dll`).
    public var importedLibraries: Set<String> = []
    /// DLLs loaded on first use, lowercased: optional paths, such as the
    /// `d3d12.dll` Unity and Unreal delay-load next to their D3D11 renderer.
    public var delayLoadedLibraries: Set<String> = []
    /// The .NET metadata version, or `nil` for a native executable.
    public var dotNetRuntimeVersion: String?
    public var referencedAssemblies: Set<String> = []
    public var engine: GameEngine?
    public var antiCheats: Set<AntiCheat> = []
    /// Whether the executable is an Electron or CEF shell whose window is a
    /// Chromium page, as many game launchers are.
    public var isChromiumApp = false
    /// The version resource's `ProductName`, `FileDescription` and `CompanyName`.
    public var versionStrings: [String: String] = [:]

    public init(url: URL) {
        self.url = url
    }

    /// The name the program gives itself: its product name, else its file description.
    public var productName: String? {
        versionStrings["ProductName"] ?? versionStrings["FileDescription"]
    }

    public var isDotNet: Bool {
        dotNetRuntimeVersion != nil
    }

    public var usesWPF: Bool {
        !referencedAssemblies.isDisjoint(with: ["PresentationFramework", "PresentationCore"])
    }

    public var usesWinForms: Bool {
        referencedAssemblies.contains("System.Windows.Forms")
    }

    /// Every graphics API the program can use, loaded at startup or on demand.
    public var graphicsAPIs: Set<GraphicsAPI> {
        Set(importedLibraries.union(delayLoadedLibraries).compactMap(GraphicsAPI.api(forImport:)))
    }

    /// The API the program most likely renders with: the newest Direct3D it
    /// loads at startup, else Vulkan, else OpenGL. Engines load older
    /// Direct3D versions for helpers (Unreal imports `d3d9.dll` next to
    /// `d3d11.dll`), so the newest one wins. Only a program that loads every
    /// renderer on demand, as Chromium does, falls back to those.
    public var primaryGraphicsAPI: GraphicsAPI? {
        let atStartup = Set(importedLibraries.compactMap(GraphicsAPI.api(forImport:)))
        return atStartup.max() ?? graphicsAPIs.max()
    }
}

/// Analyses Windows executables for the Sommelier.
public enum ExecutableAnalyzer {
    /// Analyses `url` and the files around it.
    ///
    /// - Throws: If `url` is not a readable PE file.
    public static func analyze(url: URL) throws -> ExecutableAnalysis {
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        let entries = lowercasedEntries(of: folder)

        // Velopack installs a native stub that starts `current/<same name>`;
        // the program worth analysing is the one it starts.
        var target = url
        let delegate = folder.appending(path: "current").appending(path: url.lastPathComponent)
        if entries.contains("current"), fileManager.fileExists(atPath: delegate.path(percentEncoded: false)) {
            target = delegate
        }

        let facts = try PortableExecutableReader.read(url: target)
        var analysis = ExecutableAnalysis(url: target)
        analysis.machine = facts.machine
        analysis.importedLibraries = facts.importedLibraries
        analysis.delayLoadedLibraries = facts.delayLoadedLibraries
        analysis.dotNetRuntimeVersion = facts.dotNetRuntimeVersion
        analysis.referencedAssemblies = facts.referencedAssemblies
        analysis.versionStrings = facts.versionStrings

        let targetFolder = target.deletingLastPathComponent()
        let targetEntries = target == url ? entries : lowercasedEntries(of: targetFolder)
        analysis.engine = engine(for: target, entries: targetEntries)

        if analysis.engine == .unity {
            // The Unity player executable is a thin host; UnityPlayer.dll imports the renderer.
            let player = targetFolder.appending(path: "UnityPlayer.dll")
            if let playerFacts = try? PortableExecutableReader.read(url: player) {
                analysis.importedLibraries.formUnion(playerFacts.importedLibraries)
                analysis.delayLoadedLibraries.formUnion(playerFacts.delayLoadedLibraries)
            }
        }

        // Anti-cheats sit next to the executable or one folder up (`bin/` layouts),
        // but not in folders that hold many programs: Windows installs the
        // Easy Anti-Cheat service itself in `Program Files (x86)\EasyAntiCheat`.
        var searched = targetEntries
        let parent = targetFolder.deletingLastPathComponent()
        if !sharedFolderNames.contains(parent.lastPathComponent.lowercased()) {
            searched.formUnion(lowercasedEntries(of: parent))
        }
        if analysis.engine == .unreal, let root = unrealRoot(for: target) {
            searched.formUnion(lowercasedEntries(of: root))
        }
        analysis.antiCheats = Set(AntiCheat.allCases.filter { cheat in searched.contains(where: cheat.matches) })

        // Chromium loads its renderers on demand; a game that embeds CEF for
        // an in-game browser loads its own Direct3D at startup and stays a game.
        let startupAPIs = Set(analysis.importedLibraries.compactMap(GraphicsAPI.api(forImport:)))
        analysis.isChromiumApp = startupAPIs.isDisjoint(with: [.direct3D11, .direct3D12])
            && isChromiumFolder(targetFolder, entries: targetEntries)
        return analysis
    }

    /// Folders that hold many programs rather than one program's files.
    static let sharedFolderNames: Set<String> = [
        "drive_c", "program files", "program files (x86)", "programdata", "common files",
        "users", "appdata", "local", "roaming", "games", "common", "steamapps", "steamlibrary"
    ]

    /// The engine whose runtime files sit next to `executable`.
    static func engine(for executable: URL, entries: Set<String>) -> GameEngine? {
        let baseName = executable.deletingPathExtension().lastPathComponent.lowercased()
        // Unity reads its data from `<executable name>_Data`. UnityPlayer.dll
        // alone is no sign: other programs, such as launchers, share the folder.
        if entries.contains("\(baseName)_data") {
            return .unity
        }
        if baseName.hasSuffix("-shipping") || unrealRoot(for: executable) != nil {
            return .unreal
        }
        if entries.contains("\(baseName).pck") {
            return .godot
        }
        if entries.contains("data.win") {
            return .gameMaker
        }
        return nil
    }

    /// For `<root>/<Project>/Binaries/Win64/<Project>.exe`, the `<root>` that
    /// holds the `Engine` folder of an Unreal game.
    static func unrealRoot(for executable: URL) -> URL? {
        let platform = executable.deletingLastPathComponent()
        let binaries = platform.deletingLastPathComponent()
        guard ["win64", "wingdk", "win32"].contains(platform.lastPathComponent.lowercased()),
              binaries.lastPathComponent.lowercased() == "binaries"
        else { return nil }
        let root = binaries.deletingLastPathComponent().deletingLastPathComponent()
        let engine = root.appending(path: "Engine")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: engine.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return root
    }

    /// Whether `folder` holds an Electron app (`resources/app.asar`) or the
    /// Chromium runtime files an Electron or CEF shell ships.
    static func isChromiumFolder(_ folder: URL, entries: Set<String>) -> Bool {
        let asar = folder.appending(path: "resources").appending(path: "app.asar")
        if FileManager.default.fileExists(atPath: asar.path(percentEncoded: false)) {
            return true
        }
        return entries.contains("icudtl.dat")
            && (entries.contains("chrome_100_percent.pak") || entries.contains("resources.pak"))
    }

    /// The names in `folder`, lowercased; empty if it can't be listed.
    static func lowercasedEntries(of folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return Set(names.map { $0.lowercased() })
    }
}
