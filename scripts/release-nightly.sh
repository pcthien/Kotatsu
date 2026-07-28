#!/usr/bin/env bash
#
# Build a signed nightly APK against the local kotatsu-parsers composite build and
# publish it as a GitHub release, so the in-app updater on your phone offers it.
#
# Uses the GitHub REST API via curl (no `gh` needed) so the APK asset is uploaded with
# content_type application/vnd.android.package-archive exactly — which is what the
# in-app updater filters on.
#
# Prerequisites (see docs/SELF_UPDATE.md):
#   - Android SDK installed, sdk.dir in local.properties (or ANDROID_HOME set)
#   - Signing keystore configured in local.properties (sideload.* keys)
#   - github_updates_repo in app/src/main/res/values/constants.xml points at YOUR fork
#   - A GitHub token with `contents:write` on that fork, provided via either
#       env GITHUB_TOKEN, or a `github.token=...` line in local.properties
#
# Usage: scripts/release-nightly.sh ["release notes / changelog"]
set -euo pipefail

cd "$(dirname "$0")/.."

# JDK 17 — Gradle 9 cannot run on (or produce a JDK image with) the system JDK 26.
# Forced, not defaulted: the login shell exports JAVA_HOME=JDK26, which breaks the build.
# Override with KOTATSU_JAVA_HOME if your JDK 17 lives elsewhere.
export JAVA_HOME="${KOTATSU_JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"

prop() { grep -E "^$1=" local.properties 2>/dev/null | head -1 | cut -d'=' -f2-; }

# Monotonic version = minutes since 2020-01-01 UTC. Passed to Gradle so the APK's
# versionName and this release's tag/title are identical.
STAMP=$(( ( $(date -u +%s) - 1577836800 ) / 60 ))
VERSION="N${STAMP}"

REPO="$(grep -oE '"github_updates_repo"[^>]*>[^<]+' app/src/main/res/values/constants.xml | sed -E 's/.*>//')"
if [[ "$REPO" == "KotatsuApp/Kotatsu" || -z "$REPO" ]]; then
	echo "ERROR: set github_updates_repo in app/src/main/res/values/constants.xml to YOUR fork first." >&2
	exit 1
fi

TOKEN="${GITHUB_TOKEN:-$(prop github.token)}"
if [[ -z "$TOKEN" ]]; then
	echo "ERROR: no GitHub token. Set env GITHUB_TOKEN or add github.token=... to local.properties." >&2
	exit 1
fi

NOTES="${1:-Nightly build ${VERSION}}"

echo "==> Building ${VERSION} (repo: ${REPO})"
./gradlew :app:assembleNightly -PbuildStamp="${STAMP}"

APK="$(ls -t app/build/outputs/apk/nightly/*.apk | head -1)"
[[ -f "$APK" ]] || { echo "ERROR: APK not found under app/build/outputs/apk/nightly/" >&2; exit 1; }

# Verify it is actually signed (unsigned APK cannot install as an update).
if ! "${JAVA_HOME}/bin/jarsigner" -verify "$APK" >/dev/null 2>&1; then
	echo "ERROR: $APK is not signed. Configure sideload.* keys in local.properties." >&2
	exit 1
fi

api() { curl -fsSL -H "Authorization: Bearer ${TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

echo "==> Creating GitHub release ${VERSION}"
RELEASE_JSON="$(api -X POST "https://api.github.com/repos/${REPO}/releases" \
	-d "$(NOTES="$NOTES" VERSION="$VERSION" python3 -c 'import json,os;print(json.dumps({"tag_name":os.environ["VERSION"],"name":os.environ["VERSION"],"body":os.environ["NOTES"]}))')")"

UPLOAD_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["upload_url"].split("{")[0])')"
[[ -n "$UPLOAD_URL" ]] || { echo "ERROR: could not create release." >&2; printf '%s\n' "$RELEASE_JSON" >&2; exit 1; }

echo "==> Uploading APK asset"
api -H "Content-Type: application/vnd.android.package-archive" \
	--data-binary @"$APK" \
	"${UPLOAD_URL}?name=Kotatsu-${VERSION}.apk" >/dev/null

echo "==> Done. Release: https://github.com/${REPO}/releases/tag/${VERSION}"
echo "    Open Kotatsu on your phone; the update appears on the next check."
