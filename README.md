# Safari Bookmark Sync · V0.9

[简体中文](README.zh-CN.md) · English

<img src="Assets/Cover-bidirectional.png" width="128" alt="Safari Bookmark Sync app icon">

A native macOS utility for synchronizing **bookmarks and folders** between Microsoft Edge and Safari. Choose either direction, use incremental or mirror mode, and keep complete backups of both browsers before each write.

**Status:** V0.9 / `0.9.0` is the first public preview.

## Features

- Edge → Safari by default; Safari → Edge is also available.
- Incremental merge and exact mirror in either direction.
- Automatic backups of both original files, manual backup, verification, restore, and deletion to Trash.
- Menu bar Quick Panel, plus a Dock-menu fallback when a menu bar manager hides the icon.
- On-screen / off-screen / notch visibility diagnostics and a menu icon recovery button.
- English and Simplified Chinese: Follow System or choose a language in Settings.
- Native Sync, Backups, and Settings panes, light/dark appearance, progress, and completion/error dialogs.
- Local scheduling, with no account, server, analytics, or runtime AI service.

## Requirements

- Apple Silicon Mac, macOS 13 or later.
- Microsoft Edge Stable and Safari bookmark files.
- Safari file access; macOS may require Full Disk Access for the installed app.
- Only the **destination browser** must quit before writing. Scheduled jobs skip a running destination instead of quitting it.

## Install and start

1. Download the V0.9 installer from [GitHub Releases](https://github.com/archever3322/safari-bookmark-sync/releases), then open `Safari 收藏夹同步-0.9.0-安装器.pkg` with the macOS Installer. It installs to `/Applications/Safari 收藏夹同步.app`.
2. Open the installed app. In Settings, select the Edge profile and authorize Safari’s original `~/Library/Safari/Bookmarks.plist`.
3. Click Check Access. If denied, use Open Full Disk Access Settings, add the installed app, enable it, and reopen when prompted.
4. Make a manual backup, choose the direction and mode, then verify your first sync in the destination browser.

The preview app is ad-hoc signed; the local installer is not Developer ID signed or notarized. Installer permissions do not grant Safari file access automatically.

## Sync modes

| Mode | Behavior |
| --- | --- |
| Incremental | Keep destination bookmarks, merge folders with the same name, and add missing exact URLs within each folder. |
| Mirror | Replace ordinary destination bookmarks with the source’s folder structure, names, order, and duplicates. An empty source is rejected. |

Safari Reading List and system proxy nodes are excluded from sync. Full Safari-file restore includes their state at backup time. Cloud services can propagate, merge, or overwrite local changes; this app does not disable iCloud or Edge Sync. Browser file formats are internal and may change; unsupported formats or incompatible checksums are rejected.

## Quick Panel and languages

Closing the main window keeps the circular-arrows menu item active. If Bartender hides it, move this app from Always Hide to Show. Settings → Menu Bar reports its actual position and offers recovery. The Dock’s context menu → Open Quick Panel also works without a visible status icon.

Settings → General → Language offers Follow System, English, and Simplified Chinese. Reopen the app to apply a change. User-authored profile names and historical backup descriptions retain their original language.

## Backups and privacy

Backups are stored locally in `~/Library/Application Support/SafariTabSync/FavoritesBackups/`. Each backup contains Safari’s `Bookmarks.plist`, Edge’s `EdgeBookmarks.json`, and a checksum manifest. Restore backs up current data first; restoring a pair requires both browsers to quit. Legacy Safari-only backups remain supported. Deleted backups go to Trash and are not pruned automatically.

No bookmark files, backups, logs, or local machine diagnostics are uploaded by the app. Never attach real bookmark files or unredacted backups to a public issue.

## Build and test

Install Xcode Command Line Tools, then run:

```sh
zsh build.sh
zsh test-favorites.sh
zsh package.sh
```

Optional UI checks never synchronize or close browsers:

```sh
SAFARI_SYNC_LANGUAGE=en SAFARI_SYNC_THEME=light \
  "dist/Safari 收藏夹同步.app/Contents/MacOS/SafariTabSync" --ui-smoke-test
SAFARI_SYNC_LANGUAGE=zh-Hans SAFARI_SYNC_THEME=dark \
  "dist/Safari 收藏夹同步.app/Contents/MacOS/SafariTabSync" --ui-smoke-test
```

The fixture suite checks both directions and both modes, backups, restore/rollback, profile protection, menu bar geometry, and localization formatting. A separate audit checks all bilingual resource keys and positional placeholders. Full real-browser acceptance still requires authorized files and manual verification; passing fixture tests is not a claim of compatibility with every browser release or cloud-sync setup.

## Project layout

- `Sources/`: AppKit UI, localization, bookmark formats, sync/backup logic, and menu bar support.
- `Resources/en.lproj/`, `Resources/zh-Hans.lproj/`: localized UI and bundle metadata.
- `Tests/`: synthetic-file tests; no personal bookmark fixtures.
- `Packaging/`: localized macOS Installer resources.
- `Assets/`: app artwork and image-generation prompts.
- `dist/`: local build artifacts and diagnostics, excluded from version control.

See [contributing](CONTRIBUTING.md), [security](SECURITY.md), and [changelog](CHANGELOG.md). Licensed under [MIT](LICENSE). Safari and Microsoft Edge names/marks belong to their respective owners; this project is independent of Apple and Microsoft.
