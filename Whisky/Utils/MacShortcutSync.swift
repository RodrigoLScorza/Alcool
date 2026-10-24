//
//  MacShortcutSync.swift
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
import os.log
import WhiskyKit

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "MacShortcutSync")

/// The Settings keys for mirroring Windows shortcuts as Mac apps.
enum MacShortcutPreferences {
    /// Create a Mac app for each program an installer adds a shortcut for.
    static let enabledKey = "mirrorWindowsShortcuts"
    /// Also put those apps on the Desktop, not only in `~/Applications/Alcool`.
    static let desktopKey = "mirrorWindowsShortcutsOnDesktop"

    /// Both settings are on unless the user turned them off.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var placesOnDesktop: Bool {
        UserDefaults.standard.object(forKey: desktopKey) as? Bool ?? true
    }
}

/// Turns the shortcuts Windows installers create into Mac apps, the way an
/// installed program shows up on the Windows desktop and Start Menu.
///
/// For each Start Menu or Desktop shortcut a bottle gains, the program it
/// points at is pinned in the bottle, and a Mac app that launches it is made
/// in `~/Applications/Alcool`, where Launchpad and Spotlight find it, and on
/// the Desktop. ``MacShortcutRegistry`` records every shortcut handled, so a
/// Mac app the user deletes is not created again, and the `.lnk` files stay
/// where the installer put them.
@MainActor
enum MacShortcutSync {
    /// `~/Applications/Alcool`.
    static var applicationsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications")
            .appending(path: "Alcool")
    }

    /// Bottles with a sync in progress, so overlapping triggers don't race.
    private static var syncing: Set<URL> = []

    /// Pins and mirrors every shortcut of `bottle` not handled before.
    ///
    /// - Returns: Whether programs were pinned that the bottle's program
    ///   list doesn't show yet, so the caller should rescan it.
    @discardableResult
    static func sync(bottle: Bottle) async -> Bool {
        guard bottle.isAvailable, !syncing.contains(bottle.url) else { return false }
        syncing.insert(bottle.url)
        defer { syncing.remove(bottle.url) }

        let bottleURL = bottle.url
        let driveC = bottleURL.appending(path: "drive_c")
        let username = bottle.wineUsername
        let (files, registry) = await Task.detached(priority: .utility) {
            (
                WindowsShortcuts.findShortcuts(driveC: driveC, wineUsername: username),
                MacShortcutRegistry.load(from: bottleURL)
            )
        }.value

        // Desktop shortcuts first: their name wins over a Start Menu entry
        // for the same program.
        let pending = (files.filter { $0.location == .desktop } + files.filter { $0.location == .startMenu })
            .filter { !registry.contains($0.url, driveC: driveC) }
        guard !pending.isEmpty else { return false }

        // Pinning matches shortcuts against the scanned Program Files list,
        // which is empty until the bottle has been scanned once.
        if bottle.programs.isEmpty {
            await bottle.updateInstalledPrograms()
        }

        var updated = registry
        var handledTargets: Set<String> = []
        var addedPins = false
        for file in pending {
            updated.markProcessed(file.url, driveC: driveC)
            guard let program = targetProgram(of: file, in: bottle) else { continue }
            let targetPath = program.url.path(percentEncoded: false)
            guard WindowsShortcuts.isProgramShortcut(name: file.displayName, targetPath: targetPath),
                  FileManager.default.fileExists(atPath: targetPath),
                  handledTargets.insert(targetPath.lowercased()).inserted
            else { continue }

            let name = await appName(for: file, program: program, bottleURL: bottleURL)
            addedPins = pin(program, name: name, in: bottle) || addedPins
            if MacShortcutPreferences.isEnabled {
                await mirror(program, name: name)
            }
        }

        if updated != registry {
            do {
                try updated.save(to: bottleURL)
            } catch {
                logger.error("Failed to save the shortcut registry: \(error.localizedDescription, privacy: .public)")
            }
        }
        return addedPins
    }

    /// The shortcut's name, or the program's product name when the shortcut
    /// is named like a file (see ``WindowsShortcuts/preferredName(shortcutName:executableURL:productName:)``).
    private static func appName(for file: WindowsShortcutFile, program: Program, bottleURL: URL) async -> String {
        let url = program.url
        let productName = await Task.detached(priority: .utility) {
            SommelierReportStore.report(for: url, bottleURL: bottleURL)?.productName
        }.value
        return WindowsShortcuts.preferredName(
            shortcutName: file.displayName, executableURL: url, productName: productName
        )
    }

    /// The program a `.lnk` file points at, or `nil` if it can't be read.
    private static func targetProgram(of file: WindowsShortcutFile, in bottle: Bottle) -> Program? {
        do {
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            return ShellLinkHeader.getProgram(url: file.url, handle: handle, bottle: bottle)
        } catch {
            logger.warning(
                "Failed to read shortcut \(file.url.lastPathComponent, privacy: .public): \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Pins `program` in `bottle` unless it is pinned already.
    ///
    /// A program the bottle scan found (under Program Files) is pinned in
    /// place, matching paths case-insensitively like Windows does. Anything
    /// else, such as a launcher installed under AppData, gets a new pin.
    ///
    /// - Returns: Whether a pin was added that the program list doesn't show yet.
    private static func pin(_ program: Program, name: String, in bottle: Bottle) -> Bool {
        let path = program.url.path(percentEncoded: false)
        if let scanned = bottle.programs.first(where: {
            $0.url.path(percentEncoded: false).caseInsensitiveCompare(path) == .orderedSame
        }) {
            if !scanned.pinned {
                scanned.pinned = true
            }
            return false
        }

        // One program can have several paths: a Velopack stub and the
        // `current/` program it starts, or a profile folder reached through a
        // link under another user's name.
        let identity = ExecutableAnalyzer.programIdentity(of: program.url)
        let alreadyPinned = bottle.settings.pins.contains { existing in
            existing.url.map { ExecutableAnalyzer.programIdentity(of: $0) == identity } ?? false
        }
        guard !alreadyPinned else { return false }
        bottle.settings.pins.append(PinnedProgram(name: name, url: program.url))
        return true
    }

    /// Creates the Mac apps for `program`, skipping any that already exist.
    private static func mirror(_ program: Program, name: String) async {
        let appName = WindowsShortcuts.macAppName(for: name) + ".app"
        var destinations = [applicationsFolder.appending(path: appName)]
        if MacShortcutPreferences.placesOnDesktop,
           let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            destinations.append(desktop.appending(path: appName))
        }

        for destination in destinations
            where !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                logger.error("Failed to create \(destination.path(percentEncoded: false), privacy: .public)")
                continue
            }
            await ProgramShortcut.createShortcut(program, app: destination, name: name, revealInFinder: false)
            logger.info("Created \(destination.path(percentEncoded: false), privacy: .public)")
        }
    }
}

/// Checks every bottle for new Windows shortcuts every few seconds while the
/// app runs, so an installer's shortcut becomes a Mac app moments after the
/// installer writes it, whether or not that bottle is open in the window.
@MainActor
final class MacShortcutWatcher {
    static let shared = MacShortcutWatcher()

    private static let interval = Duration.seconds(3)

    private var task: Task<Void, Never>?
    /// The shortcut files each bottle had at its last check.
    private var snapshots: [URL: Set<WindowsShortcutFile>] = [:]

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkBottles()
                try? await Task.sleep(for: MacShortcutWatcher.interval)
            }
        }
    }

    private func checkBottles() async {
        for bottle in BottleVM.shared.bottles where bottle.isAvailable {
            let driveC = bottle.url.appending(path: "drive_c")
            let username = bottle.wineUsername
            let snapshot = await Task.detached(priority: .utility) {
                Set(WindowsShortcuts.findShortcuts(driveC: driveC, wineUsername: username))
            }.value
            guard snapshots[bottle.url] != snapshot else { continue }
            snapshots[bottle.url] = snapshot
            if await MacShortcutSync.sync(bottle: bottle) {
                await bottle.updateInstalledPrograms()
            }
        }
    }
}
