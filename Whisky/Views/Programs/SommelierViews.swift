//
//  SommelierViews.swift
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

// MARK: - Wording

extension SommelierRecipe {
    var title: String {
        switch self {
        case .wpfSoftwareRendering: String(localized: "sommelier.recipe.wpfSoftwareRendering")
        case .coreFonts: String(localized: "sommelier.recipe.coreFonts")
        case .chromiumOnDXVK: String(localized: "sommelier.recipe.chromiumOnDXVK")
        }
    }
}

extension SommelierBadge {
    var title: String {
        switch self {
        case .autoAdjusted: String(localized: "sommelier.badge.autoAdjusted")
        case .antiCheat: String(localized: "sommelier.badge.antiCheat")
        case .needsD3DMetal: String(localized: "sommelier.badge.needsD3DMetal")
        }
    }

    var help: String {
        switch self {
        case .autoAdjusted: String(localized: "sommelier.badge.autoAdjusted.help")
        case .antiCheat: String(localized: "sommelier.badge.antiCheat.help")
        case .needsD3DMetal: String(localized: "sommelier.badge.needsD3DMetal.help")
        }
    }

    var systemImage: String {
        switch self {
        case .autoAdjusted: "wand.and.stars"
        case .antiCheat: "exclamationmark.shield.fill"
        case .needsD3DMetal: "cpu"
        }
    }

    /// The words a library card's status line uses for the badge.
    var statusText: String {
        switch self {
        case .autoAdjusted, .needsD3DMetal: title
        case .antiCheat: String(localized: "sommelier.status.antiCheat")
        }
    }

    /// The colour of the dot beside a card's status line.
    var statusTint: Color {
        switch self {
        case .autoAdjusted: .green
        case .antiCheat: .red
        case .needsD3DMetal: .orange
        }
    }

    /// Dark enough for white text on top.
    var tint: Color {
        switch self {
        case .autoAdjusted: Color(red: 0.13, green: 0.50, blue: 0.30)
        case .antiCheat: Color(red: 0.70, green: 0.16, blue: 0.16)
        case .needsD3DMetal: Color(red: 0.72, green: 0.38, blue: 0.05)
        }
    }
}

extension SommelierNote {
    /// What a person is told about the note, or `nil` for a plain detection.
    var message: String? {
        switch self {
        case .wpfSoftwareRendering: SommelierRecipe.wpfSoftwareRendering.title
        case .chromiumUsesDXVK: SommelierRecipe.chromiumOnDXVK.title
        case let .antiCheat(cheat): String(localized: "sommelier.warning.antiCheat \(cheat.displayName)")
        case .direct3D12WithoutD3DMetal: String(localized: "sommelier.warning.needsD3DMetal")
        case .direct3D9OnOpenGL: String(localized: "sommelier.warning.direct3D9")
        case .detected: nil
        }
    }

    var isWarning: Bool {
        switch self {
        case .antiCheat, .direct3D12WithoutD3DMetal, .direct3D9OnOpenGL: true
        case .wpfSoftwareRendering, .chromiumUsesDXVK, .detected: false
        }
    }
}

// MARK: - Program page

/// Where a program page is in getting its Sommelier report.
enum SommelierReportState: Equatable {
    case loading
    /// The file couldn't be analysed.
    case unavailable
    case loaded(SommelierReport)
}

/// What the Sommelier found in a program and what it does for it, at the top
/// of the program's page.
struct SommelierSection: View {
    let state: SommelierReportState
    let d3dMetalAvailable: Bool

    var body: some View {
        Section {
            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            case .unavailable:
                Text("sommelier.unavailable")
                    .foregroundStyle(.secondary)
            case let .loaded(report):
                rows(for: report)
            }
        } header: {
            Label("sommelier.title", systemImage: "wand.and.stars")
        } footer: {
            if case let .loaded(report) = state {
                footer(for: report)
            }
        }
    }

    @ViewBuilder
    private func rows(for report: SommelierReport) -> some View {
        if let productName = report.productName {
            LabeledContent("sommelier.product", value: productName)
        }
        if let engine = report.engine {
            LabeledContent("sommelier.engine", value: engine.displayName)
        }
        if let graphics = graphics(of: report) {
            LabeledContent("sommelier.graphics", value: graphics)
        }
        if let runtime = runtime(of: report) {
            LabeledContent("sommelier.runtime", value: runtime)
        }
        ForEach(report.recipes, id: \.self) { recipe in
            Label(recipe.title, systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.primary)
        }
        ForEach(warnings(for: report), id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
        }
        if report.recipes.isEmpty, warnings(for: report).isEmpty {
            Text("sommelier.nothingNeeded")
                .foregroundStyle(.secondary)
        }
    }

    private func footer(for report: SommelierReport) -> some View {
        Group {
            if let lastLaunch = report.lastLaunch {
                Text("sommelier.lastLaunch \(lastLaunch.formatted(.relative(presentation: .named)))")
            } else {
                Text("sommelier.notLaunched")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func graphics(of report: SommelierReport) -> String? {
        if report.isChromiumApp {
            return "Chromium (Electron/CEF)"
        }
        return report.graphicsAPI?.displayName
    }

    private func runtime(of report: SommelierReport) -> String? {
        guard let version = report.dotNetRuntime else { return nil }
        var parts = [".NET \(version)"]
        if report.usesWPF {
            parts.append("WPF")
        } else if report.usesWinForms {
            parts.append("Windows Forms")
        }
        return parts.joined(separator: " · ")
    }

    private func warnings(for report: SommelierReport) -> [String] {
        var warnings = report.antiCheats.compactMap { SommelierNote.antiCheat($0).message }
        if report.graphicsAPI == .direct3D12, !d3dMetalAvailable,
           let message = SommelierNote.direct3D12WithoutD3DMetal.message {
            warnings.append(message)
        } else if report.graphicsAPI == .direct3D9, let message = SommelierNote.direct3D9OnOpenGL.message {
            warnings.append(message)
        }
        return warnings
    }
}

// MARK: - Library card

/// The Sommelier's verdict on a library card, as a small capsule.
struct SommelierBadgeView: View {
    let badge: SommelierBadge

    var body: some View {
        Label(badge.title, systemImage: badge.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(badge.tint.opacity(0.9), in: Capsule())
            .fixedSize()
            .help(badge.help)
            .accessibilityLabel(badge.title)
    }
}

// MARK: - Announcement

/// Shows a banner when a launch gets an adjustment or a warning for the first
/// time (see ``WhiskyKit/Foundation/Notification/Name/sommelierDidAnnounce``).
struct SommelierAnnouncementModifier: ViewModifier {
    @State private var current: Banner?
    @State private var dismissTask: Task<Void, Never>?

    struct Banner: Equatable {
        let id = UUID()
        let programName: String
        let messages: [String]
        let isWarning: Bool
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let current {
                    banner(current)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: current)
            .onReceive(NotificationCenter.default.publisher(for: .sommelierDidAnnounce)) { notification in
                guard let announcement = notification.object as? SommelierAnnouncement else { return }
                show(announcement)
            }
    }

    private func banner(_ banner: Banner) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: banner.isWarning ? "exclamationmark.triangle.fill" : "wand.and.stars")
                .foregroundStyle(banner.isWarning ? .orange : .green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("sommelier.banner.title \(banner.programName)")
                    .font(.callout.weight(.medium))
                ForEach(banner.messages, id: \.self) { message in
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("sommelier.banner.dismiss"))
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder((banner.isWarning ? Color.orange : Color.green).opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.top, 10)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    private func show(_ announcement: SommelierAnnouncement) {
        let messages = announcement.notes.compactMap(\.message)
        guard !messages.isEmpty else { return }
        let stored = SommelierReportStore.storedReport(for: announcement.programURL, bottleURL: announcement.bottleURL)
        current = Banner(
            programName: stored?.productName ?? announcement.programURL.deletingPathExtension().lastPathComponent,
            messages: messages,
            isWarning: announcement.notes.contains(where: \.isWarning)
        )
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

extension View {
    /// Shows the Sommelier's first-time adjustments and warnings as a banner.
    func sommelierAnnouncements() -> some View {
        modifier(SommelierAnnouncementModifier())
    }
}
