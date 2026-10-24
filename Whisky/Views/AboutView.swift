//
//  AboutView.swift
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

/// The About window: what Alcool is, which version this is, and the people and
/// projects it is built on.
struct AboutView: View {
    static let windowID = "about"

    private struct AboutLink: Identifiable {
        let title: LocalizedStringKey
        let url: URL?
        var id: String { url?.absoluteString ?? "" }
    }

    private var links: [AboutLink] {
        [
            AboutLink(title: "about.link.source", url: URL(string: "https://github.com/RodrigoLScorza/Alcool")),
            AboutLink(title: "about.link.whisky", url: URL(string: "https://github.com/Whisky-App/Whisky")),
            AboutLink(title: "about.link.fork", url: URL(string: "https://github.com/frankea/Whisky")),
            AboutLink(title: "about.link.license", url: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html"))
        ]
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }

    private var copyright: String? {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            credits
            HStack(spacing: 14) {
                ForEach(links) { link in
                    if let url = link.url {
                        Link(link.title, destination: url)
                    }
                }
            }
            .font(.callout)
            if let copyright {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(28)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            Text(verbatim: "Alcool")
                .font(.system(size: 28, weight: .bold))
            Text("about.version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("about.tagline")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("about.credits.title")
                .font(.headline)
            Text("about.credits.whisky")
            Text("about.credits.fork")
            Text("about.credits.stack")
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The app menu's "About Alcool" item, which opens ``AboutView`` in its own
/// window instead of the standard panel.
struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("about.menu") {
            openWindow(id: AboutView.windowID)
        }
    }
}
