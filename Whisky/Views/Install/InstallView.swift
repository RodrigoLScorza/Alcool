//
//  InstallView.swift
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

/// Installing a Windows game or app: drop the installer, see what the
/// Sommelier makes of it, install. The bottle, Wine and shortcuts are taken
/// care of; only the advanced options mention them.
struct InstallView: View {
    @EnvironmentObject var bottleVM: BottleVM
    @StateObject private var model = InstallModel()
    @State private var isTargeted = false
    /// Goes back to the games.
    let openLibrary: () -> Void

    private var bottles: [Bottle] {
        bottleVM.bottles.filter { $0.isAvailable && !$0.inFlight }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("install.header")
                        .font(.system(size: 26, weight: .bold))
                    Text("install.subtitle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                content
                howItWorks
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("install.title")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .choosing:
            dropZone
        case .ready:
            if let choice = model.choice {
                choiceCard(choice)
            }
        case .preparing:
            progressCard(
                title: String(localized: "install.preparing \(model.newBottleName)"),
                detail: String(localized: "install.preparing.detail")
            )
        case .installing:
            progressCard(
                title: String(localized: "install.installing"),
                detail: String(localized: "install.installing.detail")
            )
        case let .done(programName):
            resultCard(
                systemImage: "checkmark.circle.fill",
                tint: .green,
                title: String(localized: "install.done \(programName)"),
                detail: String(localized: "install.done.detail")
            )
        case let .failed(message):
            resultCard(
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange,
                title: String(localized: "install.failed"),
                detail: message
            )
        }
    }

    // MARK: - Choosing

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
            Text("install.drop")
                .font(.title3.weight(.semibold))
            Text("install.or")
                .foregroundStyle(.secondary)
            Button("install.choose") {
                Task {
                    if let url = await InstallerLauncher.chooseInstaller() {
                        await model.choose(url)
                    }
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 230)
        .padding(28)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor.opacity(isTargeted ? 0.12 : 0.05))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(Color.accentColor.opacity(isTargeted ? 0.9 : 0.45))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.choose(url) }
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { isTargeted = targeted }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Ready

    private func choiceCard(_ choice: InstallModel.Choice) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 20))
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                    .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("install.analyzed \(choice.url.lastPathComponent)")
                        .font(.headline)
                    if let byline = [choice.productName, choice.company].compactMap(\.self).nilIfEmpty {
                        Text(byline.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            findings(choice.findings)
            advancedOptions
            HStack {
                Button("install.cancel") { model.reset() }
                Spacer()
                Button {
                    Task { await model.install() }
                } label: {
                    Text("install.now")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Where to install, for whoever wants a say in it.
    private var advancedOptions: some View {
        DisclosureGroup("install.advanced") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("install.destination", selection: $model.destination) {
                    Text("install.destination.new \(model.newBottleName)")
                        .tag(InstallModel.Destination.newBottle)
                    ForEach(bottles) { bottle in
                        Text(bottle.settings.name)
                            .tag(InstallModel.Destination.bottle(bottle.url))
                    }
                }
                if model.destination == .newBottle {
                    TextField("install.newName", text: $model.newBottleName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func findings(_ findings: [InstallModel.Finding]?) -> some View {
        if let findings {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(findings, id: \.self) { finding in
                    Label(
                        finding.text,
                        systemImage: finding.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .symbolRenderingMode(.multicolor)
                }
            }
        } else {
            Text("install.notAnalyzed")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Progress and result

    private func progressCard(title: String, detail: String) -> some View {
        HStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func resultCard(systemImage: String, tint: Color, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("install.another") { model.reset() }
                Spacer()
                Button("install.goToGames", action: openLibrary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - How it works

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("install.how")
                .font(.headline)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { steps }
                VStack(alignment: .leading, spacing: 12) { steps }
            }
        }
    }

    @ViewBuilder
    private var steps: some View {
        step(1, "install.how.1")
        step(2, "install.how.2")
        step(3, "install.how.3")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.callout.weight(.bold))
                .frame(width: 26, height: 26)
                .background(.quaternary, in: Circle())
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension Array {
    var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }
}
