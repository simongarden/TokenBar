#!/bin/zsh
# Builds, notarizes and publishes an AI Token Status (TokenBar) release.
#
#   Scripts/release.sh [--notes TEXT | --notes-file F] [--dry-run]
#
# xcodegen consistency check → tests → Release build → Developer ID signing (hardened runtime,
# secure timestamp) → AITokenStatus-<version>-<build>-<arch>.dmg (signed) → notarytool → staple →
# Gatekeeper check → Sparkle EdDSA signature + appcast.xml → local archive copy →
# GitHub Release v<version>-<build> in simongarden/TokenBar (dmg, appcast.xml, notes, SHA256SUMS).
#
# Sparkle auto-update: the app's SUFeedURL is releases/latest/download/appcast.xml, so every release
# attaches its own appcast.xml (one item: this version). The EdDSA private key lives in the login
# Keychain (generate_keys --account $TOKENBAR_SPARKLE_ACCOUNT, default TokenBar); its public key is
# SUPublicEDKey in project.yml. The dmg is signed after stapling (stapling changes its bytes).
#
# Machine-specific values come from Scripts/release.local (gitignored, sourced) or the environment:
#   TOKENBAR_TEAM_ID              Developer ID team
#   TOKENBAR_NOTARY_PROFILE       notarytool keychain profile
#   TOKENBAR_RELEASE_ARCHIVE_DIR  local release archive folder
#   TOKENBAR_SPARKLE_ACCOUNT      Keychain account of the Sparkle EdDSA key (default TokenBar)
#
# The version is MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml (committed). A real
# release refuses a dirty working tree, an unpushed HEAD, failing tests, a pbxproj out of sync
# with project.yml, or a build that is not newer than the latest GitHub Release.
# Every file name inside the dmg must be ASCII (otherwise the code seal can break when copied).
#
# 發行規則（每次正式發行）：除了建立 GitHub Release 之外，另存一份可安裝的檔案到本機——已公證並
# staple 的磁碟映像 AITokenStatus-<version>-<build>-<arch>.dmg（Developer ID 簽署），放在
# $TOKENBAR_RELEASE_ARCHIVE_DIR/<YYYYMMDD>/（YYYYMMDD 為台北時間的發行日期；資料夾不存在就建立），
# 旁邊附 AITokenStatus-<version>-<build>-SHA256SUMS.txt 與 AITokenStatus-<version>-<build>-發行說明.txt。
# 絕不覆寫既有檔案（已存在就在建置前停止）。--dry-run 會在本機完成全部步驟（含 Apple 公證），
# 但改寫到 build/release/<version>-<build>/版本發行-dry-run/<YYYYMMDD>/，不建立 GitHub Release。
set -euo pipefail
cd "${0:A:h}/.."
root=$PWD
repo_slug=simongarden/TokenBar
[[ -f Scripts/release.local ]] && source Scripts/release.local
team=${TOKENBAR_TEAM_ID:-} notary_profile=${TOKENBAR_NOTARY_PROFILE:-}
archive_root=${TOKENBAR_RELEASE_ARCHIVE_DIR:-}
sparkle_account=${TOKENBAR_SPARKLE_ACCOUNT:-TokenBar}
release_day=$(TZ=Asia/Taipei date +%Y%m%d)

dry=0 notes='' notes_file=''
while (( $# )); do
  case $1 in
    --dry-run) dry=1 ;;
    --notes) notes=${2:?}; shift ;;
    --notes-file) notes_file=${2:?}; shift ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/!p;}' "$0"; exit 0 ;;
    *) print -r -- "未知選項：$1" >&2; exit 2 ;;
  esac
  shift
done
say() { print -r -- "▸ $*"; }
die() { print -r -- "✗ $*" >&2; exit 1; }
[[ -n $team && -n $notary_profile ]] || die "請在 Scripts/release.local 設定 TOKENBAR_TEAM_ID 與 TOKENBAR_NOTARY_PROFILE"

version=$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)"/\1/p' project.yml)
build=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "([^"]+)"/\1/p' project.yml)
[[ $version =~ '^[0-9]+(\.[0-9]+){1,3}$' && $build =~ '^[0-9]+$' ]] || die "project.yml 的版本或 build 格式錯誤：$version / $build"
[[ -n $notes_file ]] && notes=$(<"$notes_file")
[[ -n $notes ]] || notes="AI Token Status $version ($build)"
tag="v$version-$build" prefix="AITokenStatus-$version-$build"
sums_name="$prefix-SHA256SUMS.txt" notes_name="$prefix-發行說明.txt" gh_notes_name="$prefix-release-notes.txt"
out="$root/build/release/$version-$build"
print -r -- "AI Token Status release $version ($build)$( (( dry )) && print -n '  [dry run: nothing is published]')"

if (( dry )); then
  archive_dest="$out/版本發行-dry-run/$release_day"
else
  [[ -n $archive_root && -d $archive_root ]] || die "找不到本機發行資料夾（TOKENBAR_RELEASE_ARCHIVE_DIR=${archive_root:-未設定}）"
  archive_dest="$archive_root/$release_day"
  # Never overwrite: refuse before building anything.
  for f in "$archive_dest/$prefix"-*.dmg(N) "$archive_dest/$sums_name" "$archive_dest/$notes_name"; do
    [[ -e $f ]] && die "本機發行資料夾已有 ${f:t}，不覆寫。"
  done
fi
xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 || die "找不到 notarytool 憑證設定檔（TOKENBAR_NOTARY_PROFILE）"

# 0. Clean, pushed tree; project in sync; build newer than the last release; tests.
if [[ -n "$(git status --porcelain)" ]]; then
  (( dry )) || die "工作目錄有未提交的變更，拒絕發行。"
  say "warning: working tree is dirty (allowed only for --dry-run)"
fi
commit=$(git rev-parse HEAD)
if command -v xcodegen >/dev/null; then
  xcodegen generate -q
  (( dry )) || git diff --quiet -- TokenBar.xcodeproj || die "TokenBar.xcodeproj 與 project.yml 不一致；請重新產生並提交。"
fi
if (( ! dry )); then
  git fetch -q origin
  git merge-base --is-ancestor HEAD origin/main || die "HEAD 尚未推送到 origin/main；請先 push。"
  gh release view "$tag" --repo $repo_slug >/dev/null 2>&1 && die "GitHub 已有 $tag；請先遞增 project.yml 的 CURRENT_PROJECT_VERSION。"
  latest=$(gh release list --repo $repo_slug --limit 100 --json tagName --jq '.[].tagName' | sed -nE 's/^v[0-9.]+-([0-9]+)$/\1/p' | sort -n | tail -1)
  (( build > ${latest:-0} )) || die "build $build 不比已發行的 $latest 新。"
fi
rm -rf "$out"; mkdir -p "$out"
say "running tests"
xcodebuild test -project TokenBar.xcodeproj -scheme TokenBar -derivedDataPath build/DD-test > "$out/tests.log" 2>&1 || die "測試失敗，拒絕發行（見 $out/tests.log）"

# 1. Build and sign.
say "build $version ($build)"
xcodebuild -project TokenBar.xcodeproj -scheme TokenBar -configuration Release -derivedDataPath build/DD \
  DEVELOPMENT_TEAM="$team" clean build > "$out/build.log" 2>&1 || die "build 失敗（見 $out/build.log）"
app="$out/TokenBar.app"; ditto build/DD/Build/Products/Release/TokenBar.app "$app"
sparkle_bin=build/DD/SourcePackages/artifacts/sparkle/Sparkle/bin
[[ -x $sparkle_bin/sign_update && -x $sparkle_bin/generate_keys ]] || die "找不到 Sparkle 工具（$sparkle_bin）"
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$app/Contents/Info.plist"; }
[[ $(plist CFBundleShortVersionString) == $version && $(plist CFBundleVersion) == $build ]] || die "App 版本不符"
identity=$(security find-identity -v -p codesigning | sed -nE "s/.*\"(Developer ID Application: .*\($team\))\"/\1/p" | head -1)
[[ -n $identity ]] || die "鑰匙圈中找不到 Developer ID Application 憑證（team ${team}）"

say "sign app (Sparkle helpers first, inside out)"
sparkle_fw="$app/Contents/Frameworks/Sparkle.framework"
[[ -d $sparkle_fw ]] || die "App 內沒有 Sparkle.framework"
fwv="$sparkle_fw/Versions/B"
for x in "$fwv/XPCServices/Installer.xpc" "$fwv/Autoupdate" "$fwv/Updater.app"; do
  [[ -e $x ]] && codesign --force --options runtime --timestamp --sign "$identity" "$x"
done
[[ -e "$fwv/XPCServices/Downloader.xpc" ]] && codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$identity" "$fwv/XPCServices/Downloader.xpc"
codesign --force --options runtime --timestamp --sign "$identity" "$sparkle_fw"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict -v "$app"
info=$(codesign -dvv "$app" 2>&1)
[[ $info == *"TeamIdentifier=$team"* && $info == *"flags=0x10000(runtime)"* && $info == *"Timestamp="* ]] || die "簽章缺少 team/runtime/timestamp"
ents=$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)
[[ $ents != *get-task-allow* ]] || die "含 get-task-allow"
[[ $(plist SUPublicEDKey) == $("$sparkle_bin/generate_keys" --account "$sparkle_account" -p 2>/dev/null) ]] || die "SUPublicEDKey 與鑰匙圈中的 Sparkle 金鑰（$sparkle_account）不符"
[[ $(plist SUFeedURL) == "https://github.com/$repo_slug/releases/latest/download/appcast.xml" ]] || die "SUFeedURL 不正確：$(plist SUFeedURL)"
[[ $(TOKENBAR_KEYCHAIN_PROBE=1 "$app/Contents/MacOS/TokenBar") == *"exists(attrs)=0"* ]] || die "鑰匙圈探測失敗"
arch=$(lipo -archs "$app/Contents/MacOS/TokenBar" | tr ' ' '-')

# 2. Disk image: signed, notarized, stapled.
dmg="$out/$prefix-$arch.dmg"
say "dmg ${dmg:t}"
root_dir="$out/dmg-root"; mkdir -p "$root_dir"; ditto "$app" "$root_dir/TokenBar.app"; ln -s /Applications "$root_dir/Applications"
bad=$(cd "$root_dir" && find . -print | LC_ALL=C grep '[^ -~]' || true); [[ -z $bad ]] || die "非 ASCII 檔名：$bad"
hdiutil create -volname "AI Token Status $version" -srcfolder "$root_dir" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg" > "$out/hdiutil.log" 2>&1 || die "hdiutil 失敗"
rm -rf "$root_dir"
codesign --sign "$identity" --timestamp -i com.okmaster.TokenBar.dmg "$dmg"
codesign --verify --strict -v "$dmg"

say "notarize (waits for Apple)"
xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait --output-format json > "$out/notary.json" || true
nid=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('id',''))" "$out/notary.json")
nst=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('status',''))" "$out/notary.json")
if [[ $nst != Accepted ]]; then
  [[ -n $nid ]] && xcrun notarytool log "$nid" --keychain-profile "$notary_profile" > "$out/notary-log.json" 2>&1 || true
  die "公證未通過（$nst，ID $nid；$out/notary-log.json）"
fi
xcrun notarytool log "$nid" --keychain-profile "$notary_profile" > "$out/notary-log.json" 2>&1 || true
xcrun stapler staple "$dmg" > "$out/staple.log" 2>&1 || die "staple 失敗"
xcrun stapler validate "$dmg" >/dev/null || die "staple 驗證失敗"
spctl -a -vv -t open --context context:primary-signature "$dmg" > "$out/spctl-dmg.log" 2>&1 || true
grep -q "Notarized Developer ID" "$out/spctl-dmg.log" || die "Gatekeeper 未認可 dmg（見 $out/spctl-dmg.log）"
mnt=$(mktemp -d /tmp/tokenbar-dmg.XXXXXX)
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$dmg" >/dev/null
spctl -a -vv -t execute "$mnt/TokenBar.app" > "$out/spctl-app.log" 2>&1 || true
hdiutil detach -quiet "$mnt" || hdiutil detach -force -quiet "$mnt"; rmdir "$mnt" 2>/dev/null || true
grep -q "Notarized Developer ID" "$out/spctl-app.log" || die "Gatekeeper 未認可 app（見 $out/spctl-app.log）"
dmg_sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
say "dmg $(stat -f %z "$dmg") bytes  sha256 $dmg_sha  notary $nid Accepted"

# 2b. Sparkle: EdDSA-sign the final (stapled) dmg, write this release's appcast.xml, sign the feed.
ed_sig=$("$sparkle_bin/sign_update" --account "$sparkle_account" -p "$dmg") || die "Sparkle 簽署失敗（鑰匙圈帳號 $sparkle_account）"
"$sparkle_bin/sign_update" --account "$sparkle_account" --verify "$dmg" "$ed_sig" >/dev/null || die "Sparkle 簽章驗證失敗"
appcast="$out/appcast.xml"
NOTES=$notes python3 - "$appcast" "$version" "$build" "$(plist LSMinimumSystemVersion)" \
  "https://github.com/$repo_slug/releases/download/$tag/${dmg:t}" "$(stat -f %z "$dmg")" "$ed_sig" "https://github.com/$repo_slug/releases/tag/$tag" <<'PY'
import html, os, sys
from email.utils import formatdate
out, version, build, minos, url, length, sig, page = sys.argv[1:]
notes = "<br>\n".join(html.escape(l) for l in os.environ["NOTES"].splitlines())
x = html.escape
open(out, "w").write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>AI Token Status</title>
    <link>{x(page)}</link>
    <item>
      <title>AI Token Status {x(version)} ({x(build)})</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{x(build)}</sparkle:version>
      <sparkle:shortVersionString>{x(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{x(minos)}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{x(page)}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{x(url)}" length="{x(length)}" type="application/octet-stream" sparkle:edSignature="{x(sig)}"/>
    </item>
  </channel>
</rss>
""")
PY
"$sparkle_bin/sign_update" --account "$sparkle_account" "$appcast" >/dev/null || die "appcast 簽署失敗"
"$sparkle_bin/sign_update" --account "$sparkle_account" --verify "$appcast" >/dev/null || die "appcast 簽章驗證失敗"
xmllint --noout "$appcast" || die "appcast.xml 格式錯誤"
say "Sparkle: dmg + appcast.xml signed (account $sparkle_account)"

# 3. Local installable copy + checksums + notes (never overwrite).
print -r -- "$notes" > "$out/$notes_name"
( cd "$out" && shasum -a 256 "${dmg:t}" "$notes_name" ) > "$out/$sums_name"
mkdir -p "$archive_dest"
for f in "$dmg" "$out/$sums_name" "$out/$notes_name"; do
  [[ -e "$archive_dest/${f:t}" ]] && die "本機發行資料夾已有 ${f:t}，不覆寫。"
  cp -n "$f" "$archive_dest/"
done
[[ $(shasum -a 256 "$archive_dest/${dmg:t}" | cut -d' ' -f1) == $dmg_sha ]] || die "複製到本機發行資料夾後檢查碼不符"
cat > "$out/SUMMARY.txt" <<SUM
AI Token Status $version ($build)  source commit ${commit:0:7}
dmg        $dmg
dmg sha256 $dmg_sha
notary     $nid Accepted
local copy $archive_dest$( (( dry )) && print -n "  (dry-run stand-in)")
release    https://github.com/$repo_slug/releases/tag/$tag
appcast    $out/appcast.xml (Sparkle EdDSA $ed_sig)
SUM
if (( dry )); then
  say "dry run complete — no GitHub Release created. Outputs: $out"
  cat "$out/SUMMARY.txt"; exit 0
fi
say "local installable copy saved: $archive_dest"
mkdir -p ~/Downloads/grok; cp -f "$dmg" ~/Downloads/grok/

# 4. GitHub Release: dmg, ASCII-named notes, SHA256SUMS covering both.
assets="$out/github-assets"; rm -rf "$assets"; mkdir -p "$assets"
cp "$dmg" "$appcast" "$assets/"; print -r -- "$notes" > "$assets/$gh_notes_name"
( cd "$assets" && shasum -a 256 "${dmg:t}" "$gh_notes_name" ) > "$out/$sums_name.github"
mv "$out/$sums_name.github" "$assets/$sums_name"
say "creating GitHub Release $tag in $repo_slug"
print -r -- "$notes" > "$out/notes.txt"
gh release create "$tag" "$assets/${dmg:t}" "$assets/appcast.xml" "$assets/$gh_notes_name" "$assets/$sums_name" \
  --repo $repo_slug --target "$commit" --title "AI Token Status $version ($build)" --notes-file "$out/notes.txt"
url="https://github.com/$repo_slug/releases/download/$tag/${dmg:t}"
code=$(curl -sL -o /dev/null -w '%{http_code}' "$url"); [[ $code == 200 ]] || die "Release 檔案無法下載（HTTP $code）：$url"
feed="https://github.com/$repo_slug/releases/latest/download/appcast.xml"
curl -sfL "$feed" | grep -q "<sparkle:version>$build</sparkle:version>" || die "Sparkle feed 尚未指向本版（$feed）"
cat "$out/SUMMARY.txt"
say "published: https://github.com/$repo_slug/releases/tag/$tag"
