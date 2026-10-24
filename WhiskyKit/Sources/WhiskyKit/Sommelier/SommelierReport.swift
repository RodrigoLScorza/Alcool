//
//  SommelierReport.swift
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

/// What the Sommelier knows about one program, kept so the interface can show
/// it without reading the executable again.
public struct SommelierReport: Codable, Equatable, Sendable {
    /// The executable's size and modification date when it was analysed. A
    /// game update changes either, and the report is made again.
    public var fileSize: UInt64
    public var modified: Date

    public var productName: String?
    /// The version resource's `CompanyName`.
    public var companyName: String?
    public var engine: GameEngine?
    /// The API it most likely renders with; `nil` for a Chromium shell, whose
    /// renderer is picked at run time.
    public var graphicsAPI: GraphicsAPI?
    public var dotNetRuntime: String?
    public var usesWPF: Bool
    public var usesWinForms: Bool
    public var isChromiumApp: Bool
    public var antiCheats: [AntiCheat]

    /// When the program was last launched with Alcool, and what the Sommelier
    /// did or found for that launch.
    public var lastLaunch: Date?
    public var lastLaunchNotes: [SommelierNote]

    public init(analysis: ExecutableAnalysis, fileSize: UInt64, modified: Date) {
        self.fileSize = fileSize
        self.modified = modified
        productName = analysis.productName
        companyName = analysis.versionStrings["CompanyName"]
        engine = analysis.engine
        graphicsAPI = analysis.isChromiumApp ? nil : analysis.primaryGraphicsAPI
        dotNetRuntime = analysis.dotNetRuntimeVersion
        usesWPF = analysis.usesWPF
        usesWinForms = analysis.usesWinForms
        isChromiumApp = analysis.isChromiumApp
        antiCheats = analysis.antiCheats.sorted { $0.rawValue < $1.rawValue }
        lastLaunch = nil
        lastLaunchNotes = []
    }

    /// The adjustments the Sommelier makes for this program on every launch.
    public var recipes: [SommelierRecipe] {
        var recipes: [SommelierRecipe] = []
        if usesWPF {
            recipes.append(.wpfSoftwareRendering)
        }
        if usesWPF || usesWinForms {
            recipes.append(.coreFonts)
        }
        if isChromiumApp {
            recipes.append(.chromiumOnDXVK)
        }
        return recipes
    }

    /// The badge a library card shows for this program, most important first.
    ///
    /// - Parameter d3dMetalAvailable: Whether the runtime serves Direct3D 12.
    public func badge(d3dMetalAvailable: Bool) -> SommelierBadge? {
        if !antiCheats.isEmpty {
            return .antiCheat
        }
        if graphicsAPI == .direct3D12, !d3dMetalAvailable {
            return .needsD3DMetal
        }
        return recipes.isEmpty ? nil : .autoAdjusted
    }
}

/// An adjustment the Sommelier applies to a kind of program.
public enum SommelierRecipe: String, Codable, Sendable, CaseIterable {
    /// WPF renders in software (`Avalon.Graphics DisableHWAcceleration=1`).
    case wpfSoftwareRendering
    /// Arial, Times New Roman and Verdana are copied into the bottle.
    case coreFonts
    /// An Electron or CEF window runs on DXVK when the backend is Recommended.
    case chromiumOnDXVK
}

/// What a library card says about a program, at a glance.
public enum SommelierBadge: String, Sendable, CaseIterable {
    /// The Sommelier adjusts the bottle for it on every launch.
    case autoAdjusted
    /// It ships an anti-cheat, which most likely refuses to run under Wine.
    case antiCheat
    /// It renders with Direct3D 12, which needs D3DMetal (Game Porting Toolkit).
    case needsD3DMetal
}

/// The Sommelier's reports for one bottle, in `Sommelier.plist` at its root,
/// keyed by each executable's path relative to `drive_c`, lowercased, so a
/// moved bottle keeps them.
public enum SommelierReportStore {
    static let fileName = "Sommelier.plist"
    private static let lock = NSLock()

    /// The report for `url`, made now when there is none or the executable
    /// changed since. `nil` when the file can't be analysed.
    public static func report(for url: URL, bottleURL: URL) -> SommelierReport? {
        guard let stamp = fileStamp(of: url) else { return nil }
        let key = key(for: url, bottleURL: bottleURL)
        // Within a second, in case a file system rounds what it reports.
        if let cached = load(bottleURL: bottleURL)[key], cached.fileSize == stamp.size,
           abs(cached.modified.timeIntervalSince(stamp.modified)) < 1 {
            return cached
        }
        guard let analysis = try? ExecutableAnalyzer.analyze(url: url) else { return nil }
        return update(key: key, bottleURL: bottleURL) { existing in
            var report = SommelierReport(analysis: analysis, fileSize: stamp.size, modified: stamp.modified)
            report.lastLaunch = existing?.lastLaunch
            report.lastLaunchNotes = existing?.lastLaunchNotes ?? []
            return report
        }
    }

    /// The stored report for `url`, without analysing anything.
    public static func storedReport(for url: URL, bottleURL: URL) -> SommelierReport? {
        load(bottleURL: bottleURL)[key(for: url, bottleURL: bottleURL)]
    }

    /// Records a launch of `url` with the notes the Sommelier made for it.
    ///
    /// - Returns: The notes worth announcing that the previous launch didn't
    ///   have: an adjustment or a warning seen for the first time.
    @discardableResult
    public static func recordLaunch(
        of url: URL, bottleURL: URL, analysis: ExecutableAnalysis, notes: [SommelierNote], at date: Date = .now
    ) -> [SommelierNote] {
        guard let stamp = fileStamp(of: url) else { return [] }
        var previous: [SommelierNote] = []
        _ = update(key: key(for: url, bottleURL: bottleURL), bottleURL: bottleURL) { existing in
            previous = existing?.lastLaunchNotes ?? []
            var report = SommelierReport(analysis: analysis, fileSize: stamp.size, modified: stamp.modified)
            report.lastLaunch = date
            report.lastLaunchNotes = notes
            return report
        }
        return notes.filter { $0.isAnnounced && !previous.contains($0) }
    }

    // MARK: - Storage

    static func key(for url: URL, bottleURL: URL) -> String {
        let driveC = bottleURL.appending(path: "drive_c").standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let relative = path.hasPrefix(driveC + "/") ? String(path.dropFirst(driveC.count + 1)) : path
        return relative.lowercased()
    }

    static func load(bottleURL: URL) -> [String: SommelierReport] {
        let url = bottleURL.appending(path: fileName)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? PropertyListDecoder().decode([String: SommelierReport].self, from: data)) ?? [:]
    }

    /// Replaces one report under the lock, so a launch and the interface
    /// writing at the same moment don't drop each other's change.
    private static func update(
        key: String, bottleURL: URL, _ change: (SommelierReport?) -> SommelierReport
    ) -> SommelierReport {
        lock.lock()
        defer { lock.unlock() }
        var reports = load(bottleURL: bottleURL)
        let report = change(reports[key])
        reports[key] = report
        // Binary keeps dates to the sub-second, as the file system reports them.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(reports) {
            try? data.write(to: bottleURL.appending(path: fileName), options: .atomic)
        }
        return report
    }

    private static func fileStamp(of url: URL) -> (size: UInt64, modified: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return (size.uint64Value, modified)
    }
}

extension SommelierNote {
    /// Whether the note is worth telling the user about the first time it
    /// appears: an adjustment, or a warning. A plain detection is not.
    public var isAnnounced: Bool {
        if case .detected = self {
            return false
        }
        return true
    }
}
