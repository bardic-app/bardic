#!/bin/zsh
# Publishes a Bardic release on GitHub: bumps VERSION, builds and signs the DMG, commits, tags,
# pushes, and uploads the DMG with notes from CHANGELOG.md.
#
# Usage: scripts/release.sh <version> [--dry-run] [--skip-eval]
#
#   --dry-run    build the DMG and show the release notes, but commit, tag and publish nothing
#   --skip-eval  don't run the cleanup eval first (it needs the cleanup model downloaded)
#
# Before running, add a "## <version>" section to CHANGELOG.md and commit it.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

NEW_VERSION=""; DRY_RUN=0; SKIP_EVAL=0
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=1 ;;
    --skip-eval) SKIP_EVAL=1 ;;
    -*) echo "Unknown option: $arg"; exit 2 ;;
    *) NEW_VERSION="${arg#v}" ;;
  esac
done
[[ -n "$NEW_VERSION" ]] || { echo "Usage: scripts/release.sh <version> [--dry-run] [--skip-eval]"; exit 2; }
[[ "$NEW_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "✗ Version must look like 1.2.3"; exit 2; }
TAG="v$NEW_VERSION"
fail() { echo "✗ $1"; exit 1 }

echo "▸ Checking the repo…"
[[ "$(git branch --show-current)" == "main" ]] || fail "Release from the main branch."
[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first (git status)."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "Tag $TAG already exists."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI isn't logged in (gh auth login)."
if (( ! DRY_RUN )); then
  git remote get-url origin >/dev/null 2>&1 || fail "No 'origin' remote. Create the GitHub repo first."
fi

# Release notes: this version's CHANGELOG section.
NOTES_BODY="$(awk -v v="## $NEW_VERSION" '
  index($0, v) == 1 { on = 1; next }
  on && /^## / { exit }
  on { print }' CHANGELOG.md)"
[[ -n "${NOTES_BODY//[[:space:]]/}" ]] || fail "CHANGELOG.md has no \"## $NEW_VERSION\" section."

# Releases are signed ad-hoc: a certificate would put its owner's name and email in the signature.
# The cost: macOS ties Accessibility to the exact build, so users re-allow it after every update.
# SIGN_IDENTITY overrides this (a "Developer ID Application" identity also enables notarization).
IDENTITY="${SIGN_IDENTITY:--}"
echo "  signing as: ${IDENTITY/#-/ad-hoc}"

if (( ! SKIP_EVAL )); then
  echo "▸ Running the cleanup eval…"
  # Same path-stripping flags as build-app.sh, so the app build reuses these compiled packages.
  PREFIX_MAP=(
    "OTHER_CFLAGS=\$(inherited) -ffile-prefix-map=$ROOT/=./"
    "OTHER_CPLUSPLUSFLAGS=\$(inherited) -ffile-prefix-map=$ROOT/=./"
    "OTHER_SWIFT_FLAGS=\$(inherited) -file-prefix-map $ROOT/=./"
  )
  xcodebuild -scheme bardic-cli -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData -skipMacroValidation -skipPackagePluginValidation "${PREFIX_MAP[@]}" build \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
  EVAL="$(build/DerivedData/Build/Products/Release/bardic-cli eval 2>/dev/null)"
  SUMMARY="$(print -r -- "$EVAL" | grep -E '^[0-9]+/[0-9]+ passed')"
  echo "  $SUMMARY"
  if print -r -- "$EVAL" | grep -q '^FAIL'; then
    print -r -- "$EVAL" | grep -A5 '^FAIL'
    fail "Eval has failures. Fix them, or pass --skip-eval if they're expected."
  fi
fi

echo "▸ Building $NEW_VERSION…"
print -r -- "$NEW_VERSION" > VERSION
VERSION="$NEW_VERSION" SIGN_IDENTITY="$IDENTITY" scripts/build-app.sh --no-install --dmg
DMG="build/Bardic-$NEW_VERSION.dmg"
[[ -f "$DMG" ]] || fail "The DMG wasn't created."
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"

NOTES="build/release-notes-$NEW_VERSION.md"
cat > "$NOTES" <<EOF
$NOTES_BODY

## Install

Requires a Mac with **Apple Silicon (M1 or later)** and **macOS 14** or later.

1. Download **Bardic-$NEW_VERSION.dmg** below, open it, and drag Bardic to Applications.
2. Open Bardic. macOS refuses the first time, because Bardic isn't registered with Apple. Click **Done**.
3. Go to **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to Bardic.
4. Follow the setup window: Microphone, Accessibility, then a one-time model download of about 3 GB.

Updating: replace the app in Applications and repeat step 3. macOS treats each version as a new app: under
Privacy & Security › Accessibility, select Bardic, click **–**, then open Bardic and allow it again.

SHA-256 of the DMG: \`$SHA\`
EOF

echo
echo "──────── release notes ($NOTES) ────────"
cat "$NOTES"
echo "─────────────────────────────────────────"

if (( DRY_RUN )); then
  git checkout -- VERSION
  echo "✓ Dry run: built $DMG ($SHA). Nothing was committed, tagged or published."
  exit 0
fi

echo "▸ Committing, tagging and pushing $TAG…"
git add VERSION
git diff --cached --quiet || git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "Bardic $NEW_VERSION"
git push origin main "$TAG"

echo "▸ Publishing the GitHub release…"
gh release create "$TAG" "$DMG" --title "Bardic $NEW_VERSION" --notes-file "$NOTES"
echo "✓ Released $TAG"
