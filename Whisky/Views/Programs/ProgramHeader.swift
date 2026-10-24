//
//  ProgramHeader.swift
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

import SwiftUI
import WhiskyKit

/// The top of a program's page: what it is, and the one thing to do with it.
struct ProgramHeader: View {
    let icon: Image?
    let name: String
    let subtitle: String
    let isLaunching: Bool
    let launch: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                identity
                Spacer(minLength: 12)
                playButton
            }
            VStack(alignment: .leading, spacing: 14) {
                identity
                playButton
            }
        }
        .padding(.vertical, 6)
    }

    private var identity: some View {
        HStack(spacing: 16) {
            Group {
                if let icon {
                    icon
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var playButton: some View {
        HStack(spacing: 10) {
            if isLaunching {
                ProgressView()
                    .controlSize(.small)
            }
            Button(action: launch) {
                Label("library.play", systemImage: "play.fill")
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLaunching)
            .keyboardShortcut(.defaultAction)
            .help("program.play.help")
        }
    }
}

/// How a program runs, in words a person picks by: the graphics backend and
/// the language. Everything else is under Advanced.
struct HowItRunsSection: View {
    @ObservedObject var program: Program

    var body: some View {
        Section {
            Picker(selection: graphicsBinding) {
                Text("program.graphics.auto").tag(GraphicsBackend.recommended)
                ForEach(offeredBackends, id: \.self) { backend in
                    Text(Self.description(of: backend)).tag(backend)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("program.graphics")
                    Text("program.graphics.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("program.language", selection: $program.settings.locale) {
                ForEach(Locales.allCases, id: \.self) { locale in
                    Text(locale.pretty()).tag(locale)
                }
            }
        } header: {
            Text("program.howItRuns")
        } footer: {
            Text("config.graphics.nextLaunch")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The concrete backends this runtime has, plus the one the program
    /// already uses, so the picker can show it.
    private var offeredBackends: [GraphicsBackend] {
        let current = program.settings.overrides?.graphicsBackend
        return GraphicsBackend.allCases.filter { backend in
            backend != .recommended && (WhiskyWineInstaller.isBackendAvailable(backend) || backend == current)
        }
    }

    /// "Automatic" is no override at all: the program follows its bottle,
    /// which Alcool sets to Recommended. Picking a backend is the same
    /// override the Advanced section's toggle makes.
    private var graphicsBinding: Binding<GraphicsBackend> {
        Binding(
            get: { program.settings.overrides?.graphicsBackend ?? .recommended },
            set: { backend in
                var overrides = program.settings.overrides ?? ProgramOverrides()
                if backend == .recommended {
                    overrides.graphicsBackend = nil
                    overrides.dxvk = nil
                    overrides.dxvkAsync = nil
                    overrides.dxvkHud = nil
                    overrides.metal4Enabled = nil
                } else {
                    let bottleSettings = program.bottle.settings
                    if overrides.graphicsBackend == nil {
                        overrides.dxvkAsync = bottleSettings.dxvkAsync
                        overrides.dxvkHud = bottleSettings.dxvkHud
                        overrides.metal4Enabled = bottleSettings.metal4Enabled
                    }
                    overrides.graphicsBackend = backend
                }
                program.settings.overrides = overrides
            }
        )
    }

    static func description(of backend: GraphicsBackend) -> String {
        switch backend {
        case .recommended: String(localized: "program.graphics.auto")
        case .d3dMetal: String(localized: "program.graphics.d3dMetal")
        case .dxmt: String(localized: "program.graphics.dxmt")
        case .dxvk: String(localized: "program.graphics.dxvk")
        case .wined3d: String(localized: "program.graphics.wined3d")
        }
    }
}
