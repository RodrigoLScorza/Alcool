//
//  ProgramShortcut.swift
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

import AppKit
import Foundation
import ImageIO
import os.log
@preconcurrency import QuickLookThumbnailing
import UniformTypeIdentifiers
import WhiskyKit

class ProgramShortcut {
    /// The icon file a shortcut bundle carries in `Contents/Resources`.
    static let iconFileName = "AppIcon"

    /// The square sizes written into a shortcut's `.icns`.
    private static let iconSizes = [16, 32, 128, 256, 512]

    @MainActor
    private static func generateThumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 512, height: 512),
            scale: 2.0,
            representationTypes: .thumbnail
        )
        guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return thumbnail.nsImage
    }

    /// Creates a shortcut `.app` bundle with the program's icon.
    ///
    /// Uses ``ShortcutCreator`` from WhiskyKit for the core bundle creation.
    /// The icon comes from the executable's own resources, the same source as
    /// the icons of pinned programs, and is written into the bundle as an
    /// `.icns`, so it travels with the app: a Finder custom icon is metadata
    /// that iCloud Desktop sync can drop. QuickLook's thumbnail is the
    /// fallback for executables without a usable icon.
    ///
    /// - Parameters:
    ///   - program: The program the shortcut launches.
    ///   - app: Where to create the `.app` bundle.
    ///   - name: The shortcut's display name.
    ///   - revealInFinder: Whether to select the new shortcut in Finder.
    ///     Shortcuts made automatically for installed programs pass `false`.
    @MainActor
    static func createShortcut(_ program: Program, app: URL, name: String, revealInFinder: Bool = true) async {
        do {
            // Core bundle creation via shared WhiskyKit logic
            let target = ShortcutCreator.liveTarget(for: program.url, bottle: program.bottle)
            let launchScript = ShortcutCreator.liveLaunchScript(for: target)
            let icon = program.peFile?.bestIcon()
            try ShortcutCreator.createShortcutBundle(
                at: app,
                launchScript: launchScript,
                name: name,
                iconFileName: icon == nil ? nil : iconFileName
            )

            let iconWritten = icon.map { writeIcon($0, into: app) } ?? false
            if !iconWritten, let image = await generateThumbnail(for: program.url) {
                NSWorkspace.shared.setIcon(
                    image,
                    forFile: app.path(percentEncoded: false),
                    options: NSWorkspace.IconCreationOptions()
                )
            }

            if revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting([app])
            }
        } catch {
            Logger.wineKit.error("Failed to create program shortcut: \(error.localizedDescription)")
        }
    }

    /// Writes `image` as `Contents/Resources/AppIcon.icns` of the bundle at `app`.
    ///
    /// - Returns: Whether the file was written.
    @MainActor
    private static func writeIcon(_ image: NSImage, into app: URL) -> Bool {
        let resources = app.appending(path: "Contents").appending(path: "Resources")
        let iconURL = resources.appending(path: iconFileName).appendingPathExtension("icns")
        do {
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        } catch {
            Logger.wineKit.error("Failed to create shortcut resources: \(error.localizedDescription)")
            return false
        }

        guard let destination = CGImageDestinationCreateWithURL(
            iconURL as CFURL,
            UTType.icns.identifier as CFString,
            iconSizes.count,
            nil
        )
        else { return false }

        var added = 0
        for side in iconSizes {
            guard let rendered = renderedImage(image, side: side) else { continue }
            CGImageDestinationAddImage(destination, rendered, nil)
            added += 1
        }
        return added > 0 && CGImageDestinationFinalize(destination)
    }

    /// `image` drawn into a `side` x `side` bitmap.
    @MainActor
    private static func renderedImage(_ image: NSImage, side: Int) -> CGImage? {
        var proposed = CGRect(x: 0, y: 0, width: side, height: side)
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}
