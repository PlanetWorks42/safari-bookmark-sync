#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="dist/Safari 收藏夹同步.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
WORK=$(mktemp -d "$PWD/dist/installer-build.XXXXXX")
mkdir -p "$WORK/Payload/Applications"
ditto "$APP" "$WORK/Payload/Applications/Safari 收藏夹同步.app"
pkgbuild --analyze --root "$WORK/Payload" "$WORK/components.plist"
python3 - "$WORK/components.plist" <<'PY'
import plistlib,sys
p=sys.argv[1]
with open(p,'rb') as f:components=plistlib.load(f)
for component in components:
    component['BundleIsRelocatable']=False
    component['BundleHasStrictIdentifier']=True
    component['BundleIsVersionChecked']=True
    component['BundleOverwriteAction']='upgrade'
with open(p,'wb') as f:plistlib.dump(components,f)
PY
pkgbuild --root "$WORK/Payload" --component-plist "$WORK/components.plist" --install-location / --ownership recommended --identifier local.SafariFavoritesSync.installer --version "$VERSION" "$WORK/SafariFavoritesSync-component.pkg"
ditto Packaging/Resources "$WORK/Resources"
python3 - "$VERSION" "$WORK/Distribution.xml" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[2]).write_text(Path('Packaging/Distribution.xml').read_text().replace('__VERSION__',sys.argv[1]))
for page in Path(sys.argv[2]).parent.joinpath('Resources').rglob('*.html'):
    page.write_text(page.read_text().replace('__VERSION__',sys.argv[1]))
PY
productbuild --distribution "$WORK/Distribution.xml" --resources "$WORK/Resources" --package-path "$WORK" "dist/Safari 收藏夹同步-${VERSION}-安装器.pkg"
echo "安装包已生成：$PWD/dist/Safari 收藏夹同步-${VERSION}-安装器.pkg"
echo "构建与验证材料：$WORK"
