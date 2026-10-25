#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p dist/ModuleCache
xcrun swiftc -swift-version 5 -module-cache-path dist/ModuleCache Sources/Localization.swift Sources/Core.swift Sources/Bookmarks.swift Tests/FavoritesTests.swift -o dist/FavoritesTests
dist/FavoritesTests
xcrun swiftc -swift-version 5 -module-cache-path dist/ModuleCache Sources/Localization.swift Sources/Core.swift Sources/Bookmarks.swift Sources/Bidirectional.swift Tests/DirectionTests.swift -o dist/DirectionTests
dist/DirectionTests
xcrun swiftc -swift-version 5 -module-cache-path dist/ModuleCache Sources/MenuBarSupport.swift Tests/MenuBarTests.swift -framework AppKit -o dist/MenuBarTests
dist/MenuBarTests
xcrun swiftc -swift-version 5 -module-cache-path dist/ModuleCache Sources/Localization.swift Tests/LocalizationTests.swift -o dist/LocalizationTests
SAFARI_SYNC_LANGUAGE=en dist/LocalizationTests
python3 Scripts/check-localizations.py
