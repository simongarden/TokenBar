#!/bin/zsh
# Build → sign (Developer ID, hardened runtime, secure timestamp) → dmg → sign dmg →
# notarize (notarytool, keychain profile YOUR_NOTARY_PROFILE) → staple → verify → copy to
# ~/Downloads/grok and $TOKENBAR_RELEASE_ARCHIVE_DIR/<YYYYMMDD>/ (Taipei date).
# The archive dir can be set in Scripts/release.local (gitignored, sourced below).
# Run under: caffeinate -imsu Scripts/release.sh
set -euo pipefail
cd "${0:A:h}/.."
root=$PWD
notary_profile=YOUR_NOTARY_PROFILE team=YOUR_TEAM_ID
identity="Developer ID Application: OKMaster Inc. ($team)"
[[ -f Scripts/release.local ]] && source Scripts/release.local
archive_root=${TOKENBAR_RELEASE_ARCHIVE_DIR:-}
release_day=$(TZ=Asia/Taipei date +%Y%m%d)
say() { print -r -- "▸ $*"; }
die() { print -r -- "✗ $*" >&2; exit 1; }

version=$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)"/\1/p' project.yml)
build=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "([^"]+)"/\1/p' project.yml)
[[ -n $version && -n $build ]] || die "project.yml 沒有版本"
out="$root/build/release/$version-$build"; rm -rf "$out"; mkdir -p "$out"
dmg="$out/AITokenStatus-$version.dmg"
xcrun notarytool history --keychain-profile $notary_profile >/dev/null 2>&1 || die "找不到 notarytool 憑證設定檔 $notary_profile"

say "build $version ($build)"
command -v xcodegen >/dev/null && xcodegen generate -q
xcodebuild -project TokenBar.xcodeproj -scheme TokenBar -configuration Release -derivedDataPath build/DD clean build > "$out/build.log" 2>&1 || die "build 失敗（$out/build.log）"
app="$out/TokenBar.app"; ditto build/DD/Build/Products/Release/TokenBar.app "$app"

say "sign app"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict -v "$app"
info=$(codesign -dvv "$app" 2>&1)
[[ $info == *"TeamIdentifier=$team"* && $info == *"flags=0x10000(runtime)"* && $info == *"Timestamp="* ]] || die "簽章缺少 team/runtime/timestamp"
ents=$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)
[[ $ents != *get-task-allow* ]] || die "含 get-task-allow"
[[ $(TOKENBAR_KEYCHAIN_PROBE=1 "$app/Contents/MacOS/TokenBar") == *"exists(attrs)=0"* ]] || die "鑰匙圈探測失敗"

say "dmg"
root_dir="$out/dmg-root"; mkdir -p "$root_dir"; ditto "$app" "$root_dir/TokenBar.app"; ln -s /Applications "$root_dir/Applications"
bad=$(cd "$root_dir" && find . -print | LC_ALL=C grep '[^ -~]' || true); [[ -z $bad ]] || die "非 ASCII 檔名：$bad"
hdiutil create -volname "AI Token Status" -srcfolder "$root_dir" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg" > "$out/hdiutil.log" 2>&1 || die "hdiutil 失敗"
rm -rf "$root_dir"
codesign --sign "$identity" --timestamp -i com.okmaster.TokenBar.dmg "$dmg"
codesign --verify --strict -v "$dmg"

say "notarize (waits for Apple)"
xcrun notarytool submit "$dmg" --keychain-profile $notary_profile --wait --output-format json > "$out/notary.json" || true
nid=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('id',''))" "$out/notary.json")
nst=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('status',''))" "$out/notary.json")
if [[ $nst != Accepted ]]; then
  [[ -n $nid ]] && xcrun notarytool log "$nid" --keychain-profile $notary_profile > "$out/notary-log.json" 2>&1 || true
  die "公證未通過（$nst，ID $nid；$out/notary-log.json）"
fi
xcrun notarytool log "$nid" --keychain-profile $notary_profile > "$out/notary-log.json" 2>&1 || true
xcrun stapler staple "$dmg" > "$out/staple.log" 2>&1 || die "staple 失敗"
xcrun stapler validate "$dmg"
spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1 | tee "$out/spctl-dmg.log"
grep -q "Notarized Developer ID" "$out/spctl-dmg.log" || die "Gatekeeper 未認可 dmg"
mnt=$(mktemp -d /tmp/tokenbar-dmg.XXXXXX)
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null
spctl -a -vv -t execute "$mnt/TokenBar.app" 2>&1 | tee "$out/spctl-app.log"
hdiutil detach -quiet "$mnt" || hdiutil detach -force -quiet "$mnt"; rmdir "$mnt" 2>/dev/null || true
grep -q "Notarized Developer ID" "$out/spctl-app.log" || die "Gatekeeper 未認可 app"

sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
( cd "$out" && shasum -a 256 "${dmg:t}" ) > "$out/AITokenStatus-$version-SHA256SUMS.txt"
mkdir -p ~/Downloads/grok; cp -f "$dmg" ~/Downloads/grok/
if [[ -n $archive_root && -d ${archive_root:h} ]]; then
  dest="$archive_root/$release_day"; mkdir -p "$dest"
  for f in "$dmg" "$out/AITokenStatus-$version-SHA256SUMS.txt"; do
    [[ -e "$dest/${f:t}" ]] && die "$dest 已有 ${f:t}，不覆寫"; cp -n "$f" "$dest/"
  done
  say "Drive copy: $dest"
else
  say "warning: 未設定 TOKENBAR_RELEASE_ARCHIVE_DIR 或上層資料夾不存在，略過封存（${archive_root:-未設定}）"
fi
say "done: ${dmg:t} sha256 $sha notary $nid Accepted"
