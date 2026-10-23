//
//  Bundle+Extensions.swift
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

/// Anchors `Bundle(for:)` to the binary WhiskyKit is linked into.
private final class WhiskyKitBundleToken {}

public extension Bundle {
    static var whiskyBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.rodrigoscorza.Alcool"
    }

    /// WhiskyKit's resource bundle (GameDB, crash patterns, troubleshooting
    /// flows, the Discord relay), or `nil` when it can't be found.
    ///
    /// SwiftPM's generated `Bundle.module` calls `fatalError` when the bundle
    /// is missing, which takes the whole app down the first time any resource
    /// is read. That happens, for example, when the app is moved while it is
    /// running: `Bundle.main` keeps pointing at the old location. Loaders read
    /// resources through this accessor instead and fall back to empty data.
    static let whiskyKitResources: Bundle? = {
        if let bundle = locateWhiskyKitResources() {
            return bundle
        }
        // Package test runs know the bundle's build-directory path; outside of
        // a test process `Bundle.module` would only reach its `fatalError`.
        if isTestProcess {
            return Bundle.module
        }
        return nil
    }()

    /// Whether this process runs tests: XCTest is loaded, Xcode started it as a
    /// test host, or a test runner was handed an `.xctest` bundle (Swift
    /// Testing under `swift test` loads no XCTest classes).
    private static var isTestProcess: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains { $0.hasSuffix(".xctest") }
    }

    /// Looks for `WhiskyKit_WhiskyKit.bundle` in the same places SwiftPM's
    /// accessor does, plus next to the test bundle for package test runs.
    private static func locateWhiskyKitResources() -> Bundle? {
        let bundleName = "WhiskyKit_WhiskyKit.bundle"
        let token = Bundle(for: WhiskyKitBundleToken.self)

        var directories: [URL?] = []
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] {
            directories.append(URL(fileURLWithPath: override))
        }
        directories += [
            // Linked into an app: Contents/Resources.
            Bundle.main.resourceURL,
            // Linked into a framework.
            token.resourceURL,
            // Command-line tools, such as WhiskyCmd in Contents/Resources.
            Bundle.main.bundleURL,
            // `swift test`: the bundle sits next to the .xctest bundle.
            token.bundleURL.deletingLastPathComponent()
        ]

        for directory in directories.compactMap(\.self) {
            if let bundle = Bundle(url: directory.appending(path: bundleName)) {
                return bundle
            }
        }
        return nil
    }
}
