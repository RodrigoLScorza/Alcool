# Alcool fork notes

Alcool is a fork of [frankea/Whisky](https://github.com/frankea/Whisky). This file lists what
differs from upstream so that syncing with upstream stays manageable.

## Rebranding scope

Only the surface changes. Internal names (`WhiskyKit`, `WhiskyCmd`, the `Whisky` Swift module,
type names, the GameDB) stay as they are upstream, so upstream changes merge with few conflicts.

| What | Upstream | Alcool |
| --- | --- | --- |
| App bundle | `Whisky.app` | `Alcool.app` (Swift module stays `Whisky`) |
| Bundle ID | `com.franke.Whisky` | `com.rodrigoscorza.Alcool` |
| CLI bundle ID | `com.franke.WhiskyCmd` | `com.rodrigoscorza.AlcoolCmd` |
| Thumbnail extension | `com.franke.Whisky.WhiskyThumbnail` | `com.rodrigoscorza.Alcool.Thumbnail` |
| Data folder | `~/Library/Application Support/com.franke.Whisky` | `~/Library/Application Support/com.rodrigoscorza.Alcool` |
| URL scheme | `whisky://` | `alcool://` |
| Shortcut launcher path | `/Applications/Whisky.app` | `/Applications/Alcool.app` |
| Help menu and issue links | frankea/Whisky | RodrigoLScorza/Alcool |
| Signing team | upstream's team | unset (each builder picks their own) |

Because the bundle ID and data folder differ, Alcool and Whisky can be installed side by side
without sharing bottles, settings or URL handling.

## Turned off until Alcool has its own infrastructure

- **Telemetry.** Upstream's PostHog project token was removed from `Whisky/Info.plist`.
  `Telemetry.start()` treats a missing token as disabled, so nothing is sent even if a user
  opts in. Add Alcool's own token here only once there is a privacy notice to go with it.
- **Automatic app updates.** `SUFeedURL` points to `https://rodrigolscorza.github.io/Alcool/appcast.xml`
  (not published yet) and `SUEnableAutomaticChecks` is `false`. Before the first release:
  generate an EdDSA key pair with Sparkle's `generate_keys`, replace `SUPublicEDKey` in
  `Whisky/Info.plist` (it still holds upstream's key), publish the appcast, then turn automatic
  checks back on.

## Still shared with upstream

- **Wine runtime download.** `DistributionConfig` still fetches `WhiskyWineVersion.plist` and
  `Libraries.tar.gz` from frankea/Whisky's GitHub Pages and Releases. Hosting Alcool's own
  runtime is a later step.
- **GitHub Actions.** CI (SwiftLint, SwiftFormat, en-GB coverage, build and tests on macOS) and
  SecretScan run on this repository as they do upstream. The workflows that need upstream's
  infrastructure — AutoAssign, Crowdin, Documentation (GitHub Pages), Release, RuntimeTrack and
  UpdateHomebrewTap — have their jobs guarded with `github.repository_owner == 'frankea'`, so they
  stay inert here and keep working upstream. TriageCommands only answers upstream's maintainers.
  Remove a guard when Alcool gets its own version of that piece (translations, docs site,
  releases, runtime tracking).
- **User-facing strings** in the localization catalogs still say "Whisky" in places, as do the
  app icon and the Discord presence text. These change in a later pass, ideally without editing
  every translation by hand.

## Alcool features and fixes

### Installed programs become Mac apps

When an installer adds a shortcut to the Start Menu or the Desktop of a bottle,
Alcool does what Windows does with it: the program shows up on the Mac.

- The program is pinned in the bottle, including programs installed outside
  Program Files (for example launchers under `AppData`, such as Velopack and
  Squirrel apps). Upstream only pinned Program Files programs and **deleted**
  the other shortcuts without pinning anything.
- A Mac app that launches it is created in `~/Applications/Alcool`, where
  Launchpad and Spotlight find it, and on the Desktop. Both are optional in
  Settings → Shortcuts.
- Shortcuts are left where the installer put them. Each one is handled once
  and recorded in `AlcoolShortcuts.plist` inside the bottle, keyed by its path
  relative to `drive_c`, so a Mac app the user deletes is not created again and
  moving the bottle keeps the record valid.
- Uninstallers, documentation, web links, `C:\windows` programs and
  Squirrel-style `Update.exe` shortcuts are skipped.
- A watcher checks every bottle every 3 seconds while Alcool runs, so the app
  appears shortly after the installer writes the shortcut, whether or not that
  bottle is open.

Code: `WhiskyKit/.../Whisky/WindowsShortcuts.swift` and `MacShortcutRegistry.swift`
(Foundation only, covered by `WindowsShortcutsTests`), and
`Whisky/Utils/MacShortcutSync.swift` in the app.

Importing or migrating a bottle mirrors its existing shortcuts once, the first
time Alcool sees it.

### Shortcut icons

Shortcuts, whether made with Create Shortcut or automatically, take the icon from
the executable's own resources (the same source as pinned programs) and carry it
as `Contents/Resources/AppIcon.icns`. Upstream relied on a QuickLook thumbnail
set as a Finder custom icon, which came out blank when the thumbnail extension
wasn't registered, and which iCloud Desktop sync can drop.

### Missing resources no longer crash the app

Reading GameDB, crash patterns, troubleshooting flows or the Discord relay went
through SwiftPM's `Bundle.module`, whose accessor calls `fatalError` when
`WhiskyKit_WhiskyKit.bundle` can't be found. That happened when the app was
moved while it was running, and the app crashed the first time a program page
loaded GameDB. Resources are now read through `Bundle.whiskyKitResources`,
which returns `nil` instead, and the loaders log the problem and carry on
without that data, in debug builds too.

### Sommelier: settings picked from what the program is

Before every launch, Alcool reads the executable (never runs it) and gives the
bottle what that kind of program is known to need. Reading takes a few
milliseconds: the PE import and delay-load import tables, the .NET metadata
`#Strings` heap, and the names of the files next to the executable.

| Found | Done |
| --- | --- |
| WPF (.NET `PresentationFramework`/`PresentationCore`) | `HKCU\Software\Microsoft\Avalon.Graphics` `DisableHWAcceleration=1`, once per bottle, plus Arial, Times New Roman and Verdana copied from macOS. WPF draws through Direct3D 9, which lands on wined3d's OpenGL path and leaves the window white. |
| WinForms | The same core fonts. |
| Electron or CEF shell (`resources/app.asar`, or `icudtl.dat` with `.pak` files, and no Direct3D 11/12 at startup) | DXVK, when the backend is left on Recommended. Chromium draws nothing on DXMT. |
| Easy Anti-Cheat, BattlEye, XIGNCODE3, GameGuard, PunkBuster, ACE | A warning in the run log. |
| Direct3D 12 at startup without D3DMetal, or Direct3D 9 | A note in the run log. |

Details that matter:

- A Velopack stub is analysed through `current/<same name>.exe`, the program it starts.
- Unity is recognised only by `<name>_Data`, and its renderer read from `UnityPlayer.dll`;
  Unreal by `Binaries/Win64` with an `Engine` folder next to the project.
- Delay-loaded DLLs only count when nothing is loaded at startup: Unity and Unreal
  delay-load `d3d12.dll` next to their Direct3D 11 renderer.
- Anti-cheats are looked for next to the executable and one folder up, but not in
  shared folders such as `Program Files (x86)`, where Windows installs the EAC service.
- A WPF registry value someone already set is left alone, and nothing is written when
  `user.reg` can't be read. A failed import never fails the launch.
- Nothing overrides a backend the user picked, or the plan of a game Steam launches.
- What was done is written under the run log header as `Sommelier:` lines.

What the Sommelier knows is visible in the app:

- **Program page:** a Sommelier section at the top with the product name (from the executable's
  version resource), engine, graphics API, .NET runtime, the adjustments it applies, warnings, and
  the last launch.
- **Library:** pinned programs get a badge: *Auto-adjusted*, *Anti-cheat* or *Needs D3DMetal*.
- **Banner:** the first time a program's launch gets an adjustment or a warning.
- Reports are kept per program in `Sommelier.plist` at the bottle's root, keyed by the path under
  `drive_c`, and made again when the executable's size or date changes.
- One program reached by several paths (a Velopack stub and its `current/` program, or a profile
  folder linked under another user name) is pinned and listed once
  (`ExecutableAnalyzer.programIdentity(of:)`), and a pin or Mac app named like a file
  ("MagicWings.Launcher") takes the product name ("Magic Wings").

Code: `WhiskyKit/.../Sommelier/` (reader, analyzer, advice, reports, launch integration), called from
`Wine.prepareProgramLaunch`; tests in `SommelierTests`, `SommelierLaunchTests` and the
`SyntheticPE` builder.

## Syncing with upstream

```bash
git remote add upstream https://github.com/frankea/Whisky.git
git fetch upstream
git merge upstream/main
```

Conflicts are expected only in the files listed above.
