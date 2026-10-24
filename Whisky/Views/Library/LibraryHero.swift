//
//  LibraryHero.swift
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

/// The game played last, large, at the top of the library: most launches are
/// the same game as yesterday, so it gets one click from opening the app.
struct LibraryHero: View {
    let row: LibraryRow
    let state: LibraryEntryState
    let launch: () -> Void
    let details: () -> Void

    @State private var icon: Image?
    @State private var palette: IconPalette = .neutral

    private var title: String {
        row.item.launcher?.displayName ?? row.title ?? row.item.name
    }

    var body: some View {
        // Side by side when the window is wide enough, stacked when it isn't.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) {
                iconTile
                info
                Spacer(minLength: 12)
                buttons
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    iconTile
                    info
                }
                buttons
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: [Color(palette.deepened()), Color(palette.deepened(toLuminance: 0.07))],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .task(id: row.item.id) {
            await loadIcon()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("library.continue"))
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.black.opacity(0.22))
            .frame(width: 96, height: 96)
            .overlay {
                if let icon {
                    icon
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 68, height: 68)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                }
            }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("library.continue")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.75))
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 10) {
                if state == .running {
                    Text("library.card.running")
                } else if let lastPlayed = row.lastPlayed {
                    Text("library.played \(lastPlayed.formatted(.relative(presentation: .named)))")
                }
                if let badge = row.badge {
                    SommelierBadgeView(badge: badge)
                }
            }
            .font(.callout)
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("library.details", action: details)
                .controlSize(.large)
            Button(action: launch) {
                Label("library.play", systemImage: "play.fill")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(state != .idle)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func loadIcon() async {
        guard let iconURL = row.item.iconURL else {
            palette = .neutral
            return
        }
        let sampled = await IconCache.shared.sampledIcon(for: iconURL)
        palette = sampled.palette
        icon = Image(nsImage: sampled.image)
    }
}

/// The last card of the grid: the way to put another game in it.
struct AddGameCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                Text("library.addGame")
                    .font(.headline)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 132)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
