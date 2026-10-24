//
//  LibraryCard.swift
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

extension Color {
    init(_ palette: IconPalette) {
        self.init(.sRGB, red: palette.red, green: palette.green, blue: palette.blue)
    }
}

/// Where an entry is in a launch.
enum LibraryEntryState: Equatable {
    /// Not started, or started and already exited.
    case idle
    /// Whisky has been asked to start it and Wine has not put a window up yet.
    case launching
    /// It has a process of its own in ``ProcessRegistry``.
    case running
}

/// One library entry, coloured by its own icon.
///
/// Landscape rather than the portrait box art other launchers use, because they
/// download 600x900 posters and we have a 32 to 256px icon out of the
/// executable. Stretching an icon into a poster looks broken; a wide card is the
/// shape an icon and a name actually want, and it leaves the icon at its native
/// size where it stays crisp.
struct LibraryCard: View {
    let item: LibraryEntry
    /// Only shown when there is more than one bottle, since with a single bottle
    /// the prefix is plumbing and naming it on every card is noise.
    let bottleName: String?
    let lastPlayed: Date?
    let state: LibraryEntryState
    /// What the Sommelier says about the program, shown while it is idle.
    var badge: SommelierBadge?
    /// A better name than the entry's own (see ``LibraryRow/title``).
    var displayName: String?
    let launch: () -> Void

    @State private var icon: Image?
    @State private var artwork: Image?
    @State private var palette: IconPalette = .neutral
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// A launcher is named by what it is. A pin takes its name from the
    /// executable, which is how the Steam client ends up on screen as "steam".
    private var title: String { item.launcher?.displayName ?? displayName ?? item.name }

    var body: some View {
        Button(action: launch) {
            card
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        // The system ring is a rectangle around the button's frame, so on a
        // rounded card it draws a second, squarer outline outside the one below
        // that follows the card's own shape.
        .focusEffectDisabled()
        .onKeyPress(.return) {
            launch()
            return .handled
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
        .task(id: item.id) {
            await loadIcon()
        }
        .accessibilityLabel(title)
        .accessibilityValue(Text(subtitle))
        .accessibilityHint(Text("library.card.hint"))
    }

    /// Hover is a mouse-only signal, so anything shown only on hover does not
    /// exist for somebody on the keyboard.
    private var isActive: Bool { isHovering || isFocused }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    /// A calm card: the window's own surface, the program's colour kept to its
    /// icon tile, and one status line that says what matters about it.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let artwork {
                // Steam cached this art inside the bottle. It heads the card as
                // a banner rather than being squeezed into the icon tile. Sized
                // by an empty layer: scaledToFill on its own reports the image's
                // size upward and the card grows to fit it.
                Color.clear
                    .frame(height: 78)
                    .overlay {
                        artwork
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    if artwork == nil {
                        iconTile
                    }
                    Spacer(minLength: 8)
                    statusView
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        // Tail, not middle: a game's name is recognisable from its
                        // start, and "The Elder Scro...Special Edition" reads worse
                        // than losing the edition suffix.
                        .truncationMode(.tail)
                    statusLine
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(.background.secondary, in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color(nsColor: .separatorColor).opacity(isActive ? 1 : 0.6), lineWidth: 1)
        }
        .overlay {
            if isFocused {
                shape.strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .shadow(color: .black.opacity(isActive ? 0.18 : 0.06), radius: isActive ? 10 : 4, y: 2)
        .scaleEffect(isActive ? 1.015 : 1)
    }

    /// The top-right corner: a launch in progress, or the offer to start it.
    /// Running shows in the status line instead.
    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .launching:
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
                .help("library.card.launching")
        case .running:
            EmptyView()
        case .idle:
            if isActive {
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .cardGlass(.circle, interactive: true)
                    .transition(.opacity.combined(with: .scale))
            }
        }
    }

    /// The program's icon on its own colour, which is what tells cards apart
    /// at a glance now that the cards themselves are calm.
    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(palette.deepened()))
            .frame(width: 52, height: 52)
            .overlay {
                if let icon {
                    icon
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 36, height: 36)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
            }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if let statusTint {
                Circle()
                    .fill(statusTint)
                    .frame(width: 7, height: 7)
            }
            Text(subtitle)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// The dot's colour: running, or the Sommelier's verdict.
    private var statusTint: Color? {
        if state == .running {
            return .green
        }
        return badge?.statusTint
    }

    /// What matters first: running, then the Sommelier's verdict, then why an
    /// entry is here at all ("Steam") and when it last ran.
    private var subtitle: String {
        var parts: [String] = []
        if state == .running {
            parts.append(String(localized: "library.card.running"))
        } else if let badge {
            parts.append(badge.statusText)
        }
        if item.isLauncher {
            parts.append(String(localized: "library.card.launcher"))
        }
        if item.source == .steam {
            parts.append(String(localized: "library.source.steam"))
        }
        if state != .running {
            if let lastPlayed {
                parts.append(lastPlayed.formatted(.relative(presentation: .named)))
            } else {
                parts.append(String(localized: "library.card.neverRun"))
            }
        }
        if let bottleName {
            parts.append(bottleName)
        }
        return parts.joined(separator: " · ")
    }

    /// Decoding and palette sampling both happen inside ``IconCache``, which is
    /// where the reasoning about repeating them lives.
    private func loadIcon() async {
        if let artworkURL = item.artworkURL,
           let sampled = await IconCache.shared.sampledArtwork(for: artworkURL) {
            artwork = Image(nsImage: sampled.image)
            // Still sampled: the border and the hover glow pick up the art's own
            // colour, so a card reads as one object rather than art in a frame.
            palette = sampled.palette
            return
        }
        guard let iconURL = item.iconURL else {
            palette = .neutral
            return
        }
        let sampled = await IconCache.shared.sampledIcon(for: iconURL)
        palette = sampled.palette
        icon = Image(nsImage: sampled.image)
    }
}

private extension View {
    /// Liquid Glass where the system has it, a plain material where it does not.
    /// The affordance matters more than the material, so the older path is a
    /// real control rather than nothing.
    @ViewBuilder
    func cardGlass(_ shape: some Shape, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.thinMaterial, in: shape)
        }
    }
}
