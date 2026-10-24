//
//  Sommelier.swift
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

/// Something the Sommelier did or noticed for a launch, recorded in the
/// program's run log so a failed launch explains itself.
public enum SommelierNote: Equatable, Sendable, Codable {
    /// WPF draws through Direct3D 9, which reaches Wine's OpenGL path on
    /// macOS and leaves the window blank, so WPF renders in software instead.
    case wpfSoftwareRendering
    /// Electron and CEF windows only render on DXVK (see ``GraphicsBackendResolver``).
    case chromiumUsesDXVK
    case antiCheat(AntiCheat)
    /// Direct3D 12 needs D3DMetal, which the installed runtime doesn't deploy.
    case direct3D12WithoutD3DMetal
    /// Direct3D 9 runs on Wine's OpenGL translation, whatever the backend.
    case direct3D9OnOpenGL
    case detected(engine: GameEngine?, api: GraphicsAPI?, dotNetRuntime: String?)

    /// The note as a run log line.
    public var logLine: String {
        switch self {
        case .wpfSoftwareRendering:
            "WPF app: software rendering enabled (Avalon.Graphics DisableHWAcceleration=1)"
        case .chromiumUsesDXVK:
            "Electron/CEF window: using DXVK, the backend Chromium renders on"
        case let .antiCheat(cheat):
            "\(cheat.displayName) found: most anti-cheats refuse to run under Wine on macOS"
        case .direct3D12WithoutD3DMetal:
            "Direct3D 12 program: needs D3DMetal (import Game Porting Toolkit in Settings)"
        case .direct3D9OnOpenGL:
            "Direct3D 9 program: runs through Wine's OpenGL translation"
        case let .detected(engine, api, dotNetRuntime):
            "Detected: " + [
                engine?.displayName,
                api?.displayName,
                dotNetRuntime.map { ".NET \($0)" }
            ].compactMap(\.self).joined(separator: ", ")
        }
    }
}

/// What the Sommelier recommends for one executable.
public struct SommelierAdvice: Equatable, Sendable {
    /// Turn WPF's hardware acceleration off in the bottle.
    public var softwareRenderWPF = false
    /// Make sure the bottle has the core Windows fonts the UI asks for.
    public var installCoreFonts = false
    /// The backend to run on when the bottle leaves the choice to Alcool,
    /// or `nil` to use the one Alcool recommends for the machine.
    public var preferredBackend: GraphicsBackend?
    public var notes: [SommelierNote] = []
    /// The analysis behind the advice, when a launch made it.
    public var analysis: ExecutableAnalysis?

    public init() {}
}

/// Picks the settings a Windows program needs from what it is, the way a
/// sommelier pairs a wine with a dish: the program is analysed before it
/// launches, and the bottle gets the fixes that program is known to need.
///
/// Version 0 covers what testing showed: WPF apps (blank windows), Electron
/// and CEF launchers (no window off DXVK), anti-cheats (refuse to run), and
/// Direct3D versions no installed backend serves.
public enum Sommelier {
    /// The advice for an analysed executable.
    ///
    /// - Parameters:
    ///   - analysis: What ``ExecutableAnalyzer`` found.
    ///   - d3dMetalAvailable: Whether the runtime can serve Direct3D 12 through D3DMetal.
    public static func advice(for analysis: ExecutableAnalysis, d3dMetalAvailable: Bool) -> SommelierAdvice {
        var advice = SommelierAdvice()
        // Chromium loads every renderer on demand and picks one at run time;
        // naming one, or warning about the Direct3D 12 it may never use,
        // would mislead.
        let api = analysis.isChromiumApp ? nil : analysis.primaryGraphicsAPI

        if analysis.engine != nil || api != nil || analysis.isDotNet {
            advice.notes.append(.detected(
                engine: analysis.engine,
                api: api,
                dotNetRuntime: analysis.dotNetRuntimeVersion
            ))
        }

        if analysis.usesWPF {
            advice.softwareRenderWPF = true
            advice.installCoreFonts = true
            advice.notes.append(.wpfSoftwareRendering)
        } else if analysis.usesWinForms {
            advice.installCoreFonts = true
        }

        if analysis.isChromiumApp {
            advice.preferredBackend = .dxvk
            advice.notes.append(.chromiumUsesDXVK)
        }

        if api == .direct3D12, !d3dMetalAvailable {
            advice.notes.append(.direct3D12WithoutD3DMetal)
        } else if api == .direct3D9 {
            advice.notes.append(.direct3D9OnOpenGL)
        }

        advice.notes += analysis.antiCheats
            .sorted { $0.rawValue < $1.rawValue }
            .map { SommelierNote.antiCheat($0) }
        return advice
    }
}
