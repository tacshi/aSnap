#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="aSnap"
PUBSPEC_FILE="$PROJECT_DIR/pubspec.yaml"
RELEASE_ENTITLEMENTS="$PROJECT_DIR/macos/Runner/Release.entitlements"
BUILD_OUTPUT_APP="$PROJECT_DIR/build/macos/Build/Products/Release/$APP_NAME.app"
RELEASES_DIR="$PROJECT_DIR/releases"
GITHUB_REPO="tacshi/aSnap"

DRY_RUN=false
NO_UPLOAD=false
NO_TAG=false
NO_NOTARIZE=false
CLEAN=false
BUILD_NAME=""
BUILD_NUMBER=""
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="$APP_NAME"

declare -a CLEANUP_PATHS=()

usage() {
    cat <<EOF
Build, sign, and optionally notarize a macOS release for $APP_NAME.

Usage:
  ./scripts/release.sh [VERSION] [OPTIONS]

Examples:
  ./scripts/release.sh
  ./scripts/release.sh 0.6.0
  ./scripts/release.sh 0.6.1 --build-number 2
  ./scripts/release.sh --no-upload
  ./scripts/release.sh --no-notarize
  ./scripts/release.sh --dry-run

Options:
  --build-number N       Override the build number from pubspec.yaml
  --identity NAME        Use a specific Developer ID Application identity
  --no-upload            Build locally without creating a GitHub release
  --no-tag               Skip local tag creation and let GitHub create the tag
  --no-notarize          Skip notarization and stapling
  --clean                Run flutter clean before building
  --dry-run              Validate prerequisites without building
  -h, --help             Show this help text

Notes:
  - VERSION defaults to the version in pubspec.yaml.
  - Passing VERSION updates pubspec.yaml to the release version before building.
  - The script does not integrate Sparkle or any auto-update settings.
  - The script produces a signed app bundle and DMG in ./releases.
  - By default it also creates a GitHub release in $GITHUB_REPO and uploads the DMG.
  - Notarization uses the notarytool keychain profile named: aSnap.
  - If no working notarytool profile is configured, the script falls back to a signed-only build.
EOF
}

cleanup() {
    local path

    if [[ ${#CLEANUP_PATHS[@]} -eq 0 ]]; then
        return
    fi

    for path in "${CLEANUP_PATHS[@]}"; do
        [[ -n "$path" ]] && rm -rf "$path"
    done
}

trap cleanup EXIT

log_step() {
    echo "" >&2
    echo -e "${BLUE}============================================================${NC}" >&2
    echo -e "${BLUE}$1${NC}" >&2
    echo -e "${BLUE}============================================================${NC}" >&2
}

log_success() {
    echo -e "${GREEN}[ok]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[warn]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[error]${NC} $1" >&2
}

log_info() {
    echo "  $1" >&2
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Required command not found: $1"
        exit 1
    fi
}

parse_pubspec_version() {
    local version_line

    version_line=$(sed -n 's/^version:[[:space:]]*//p' "$PUBSPEC_FILE" | head -n 1 | tr -d "\"'")
    if [[ -z "$version_line" ]]; then
        log_error "Failed to read version from $PUBSPEC_FILE"
        exit 1
    fi

    echo "$version_line"
}

split_pubspec_version() {
    local version_line="$1"

    CURRENT_BUILD_NAME="${version_line%%+*}"
    if [[ "$version_line" == *"+"* ]]; then
        CURRENT_BUILD_NUMBER="${version_line##*+}"
    else
        CURRENT_BUILD_NUMBER="1"
    fi
}

update_pubspec_version() {
    local target_version_line="$1"

    TARGET_PUBSPEC_VERSION="$target_version_line" perl -0pi -e 's/^version:\s*.*/version: $ENV{TARGET_PUBSPEC_VERSION}/m' "$PUBSPEC_FILE"
}

resolve_identity() {
    local matches=()

    if [[ -n "$IDENTITY" ]]; then
        echo "$IDENTITY"
        return
    fi

    while IFS= read -r match; do
        [[ -n "$match" ]] && matches+=("$match")
    done < <(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p')

    if [[ ${#matches[@]} -eq 0 ]]; then
        log_error "No Developer ID Application identity found."
        log_info "Install a Developer ID Application certificate or set DEVELOPER_ID_APPLICATION."
        exit 1
    fi

    if [[ ${#matches[@]} -gt 1 ]]; then
        log_error "Multiple Developer ID Application identities found. Pass --identity or set DEVELOPER_ID_APPLICATION."
        for match in "${matches[@]}"; do
            log_info "$match"
        done
        exit 1
    fi

    IDENTITY="${matches[0]}"
    echo "$IDENTITY"
}

generate_release_notes() {
    local prev_tag
    local notes

    prev_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    notes=""

    if [[ -n "$prev_tag" ]]; then
        notes=$(git log "$prev_tag"..HEAD --pretty=format:"- %s" --no-merges 2>/dev/null | \
            grep -v "^- Bump version" | \
            grep -v "^- Merge " | \
            grep -v "^- v[0-9]" | \
            grep -v "^- Release " | \
            head -20)
    else
        notes=$(git log --pretty=format:"- %s" --no-merges -20 2>/dev/null | \
            grep -v "^- Bump version" | \
            grep -v "^- Merge " | \
            grep -v "^- v[0-9]" | \
            grep -v "^- Release " | \
            head -20)
    fi

    if [[ -z "$notes" ]]; then
        notes="- Bug fixes and improvements"
    fi

    echo "$notes"
}

ensure_clean_tracked_worktree() {
    local dirty_status

    dirty_status=$(git status --short --untracked-files=no)
    if [[ -n "$dirty_status" ]]; then
        log_error "Tracked working tree changes detected. Commit or stash them before publishing a GitHub release."
        echo "$dirty_status" >&2
        exit 1
    fi
}

sign_nested_code() {
    local app_path="$1"
    local frameworks_dir="$app_path/Contents/Frameworks"

    if [[ ! -d "$frameworks_dir" ]]; then
        return
    fi

    while IFS= read -r signable; do
        [[ -n "$signable" ]] || continue
        log_info "Signing $(basename "$signable")"
        codesign --force --sign "$IDENTITY" --options runtime --timestamp "$signable"
    done < <(
        find "$frameworks_dir" \
            \( -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) -o -type f \( -name '*.dylib' -o -name '*.so' \) \) \
            | awk -F/ '{ print NF ":" $0 }' \
            | sort -nr \
            | cut -d: -f2-
    )
}

create_dmg() {
    local signed_app_path="$1"
    local dmg_path="$2"
    local dmg_temp

    dmg_temp=$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.release.XXXXXX")
    CLEANUP_PATHS+=("$dmg_temp")

    ditto "$signed_app_path" "$dmg_temp/$APP_NAME.app"
    ln -s /Applications "$dmg_temp/Applications"

    rm -f "$dmg_path"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$dmg_temp" \
        -ov \
        -format UDZO \
        "$dmg_path" >&2
}

notarize_and_staple() {
    local signed_app_path="$1"
    local dmg_path="$2"
    local submit_output
    local submission_id

    if ! submit_output=$(xcrun notarytool submit "$dmg_path" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json 2>&1); then
        log_error "Notarization submission failed."
        echo "$submit_output" >&2
        exit 1
    fi

    if ! echo "$submit_output" | grep -q '"status"[[:space:]]*:[[:space:]]*"Accepted"'; then
        log_error "Notarization was not accepted."
        echo "$submit_output" >&2

        submission_id=$(echo "$submit_output" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
        if [[ -n "$submission_id" ]]; then
            log_info "Fetching notarization log for $submission_id"
            xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        fi
        exit 1
    fi

    log_success "Notarization accepted"

    xcrun stapler staple "$signed_app_path" >&2
    xcrun stapler staple "$dmg_path" >&2
    log_success "Stapled app and DMG"

    spctl -a -t exec -vv "$signed_app_path" >&2
    log_success "Gatekeeper assessment passed"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-number)
            if [[ $# -lt 2 ]]; then
                log_error "--build-number requires a value"
                exit 1
            fi
            BUILD_NUMBER="$2"
            shift 2
            ;;
        --identity)
            if [[ $# -lt 2 ]]; then
                log_error "--identity requires a value"
                exit 1
            fi
            IDENTITY="$2"
            shift 2
            ;;
        --no-upload)
            NO_UPLOAD=true
            shift
            ;;
        --no-tag)
            NO_TAG=true
            shift
            ;;
        --no-notarize)
            NO_NOTARIZE=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [[ -n "$BUILD_NAME" ]]; then
                log_error "Only one VERSION argument is supported"
                exit 1
            fi
            BUILD_NAME="$1"
            shift
            ;;
    esac
done

PUBSPEC_VERSION=$(parse_pubspec_version)
split_pubspec_version "$PUBSPEC_VERSION"

if [[ -z "$BUILD_NAME" ]]; then
    BUILD_NAME="$CURRENT_BUILD_NAME"
fi

if [[ -z "$BUILD_NUMBER" ]]; then
    if [[ "$BUILD_NAME" == "$CURRENT_BUILD_NAME" ]]; then
        BUILD_NUMBER="$CURRENT_BUILD_NUMBER"
    else
        BUILD_NUMBER=$((CURRENT_BUILD_NUMBER + 1))
    fi
fi

ARTIFACT_BASENAME="$APP_NAME-$BUILD_NAME-$BUILD_NUMBER"
SIGNED_APP_PATH="$RELEASES_DIR/$ARTIFACT_BASENAME.app"
DMG_PATH="$RELEASES_DIR/$ARTIFACT_BASENAME.dmg"
TARGET_PUBSPEC_VERSION="$BUILD_NAME+$BUILD_NUMBER"
TAG_NAME="v$BUILD_NAME"
RELEASE_URL="https://github.com/$GITHUB_REPO/releases/tag/$TAG_NAME"

log_step "1. Validating prerequisites"

if ! [[ "$BUILD_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    log_error "Invalid VERSION format: $BUILD_NAME"
    exit 1
fi

if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    log_error "Invalid build number: $BUILD_NUMBER"
    exit 1
fi

for file_path in "$PUBSPEC_FILE" "$RELEASE_ENTITLEMENTS"; do
    if [[ ! -f "$file_path" ]]; then
        log_error "Required file not found: $file_path"
        exit 1
    fi
done

for cmd in flutter codesign security ditto hdiutil xcrun spctl git; do
    require_command "$cmd"
done

if [[ "$NO_UPLOAD" == "false" ]]; then
    require_command gh
    if ! gh auth status >/dev/null 2>&1; then
        log_error "gh is not authenticated. Run: gh auth login"
        exit 1
    fi
    log_success "GitHub CLI configured"
fi

IDENTITY=$(resolve_identity)

if [[ "$NO_NOTARIZE" == "false" ]]; then
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        log_success "Notary profile available: $NOTARY_PROFILE"
    else
        log_warning "No notarytool credentials found for keychain profile: $NOTARY_PROFILE"
        log_info "Create one with: xcrun notarytool store-credentials $NOTARY_PROFILE ..."
        log_info "Continuing with a signed build and skipping notarization."
        NO_NOTARIZE=true
    fi
else
    log_warning "Notarization disabled"
fi

log_success "Developer ID identity selected"
log_info "$IDENTITY"
log_info "Current: $CURRENT_BUILD_NAME (build $CURRENT_BUILD_NUMBER)"
log_info "Release: $BUILD_NAME (build $BUILD_NUMBER)"
log_info "Artifact prefix: $ARTIFACT_BASENAME"

RELEASE_NOTES=$(generate_release_notes)
log_info "Release notes preview:"
echo "$RELEASE_NOTES" | head -5 | while IFS= read -r line; do
    log_info "  $line"
done

if [[ "$DRY_RUN" == "true" ]]; then
    log_step "DRY RUN COMPLETE"
    log_success "All release prerequisites look good"
    exit 0
fi

log_step "2. Updating version metadata"

if [[ "$PUBSPEC_VERSION" != "$TARGET_PUBSPEC_VERSION" ]]; then
    update_pubspec_version "$TARGET_PUBSPEC_VERSION"
    git add "$PUBSPEC_FILE"
    if ! git diff --cached --quiet -- "$PUBSPEC_FILE"; then
        git commit -m "Bump version to $BUILD_NAME (build $BUILD_NUMBER)" -- "$PUBSPEC_FILE"
        log_success "Updated pubspec.yaml to $TARGET_PUBSPEC_VERSION"
    else
        log_info "No version changes were staged"
    fi
else
    log_info "pubspec.yaml already at $TARGET_PUBSPEC_VERSION"
fi

if [[ "$NO_UPLOAD" == "false" ]]; then
    ensure_clean_tracked_worktree
fi

log_step "3. Building release app"

if [[ "$CLEAN" == "true" ]]; then
    log_info "Running flutter clean"
    flutter clean >&2
fi

flutter build macos --release --build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER" >&2

if [[ ! -d "$BUILD_OUTPUT_APP" ]]; then
    log_error "Build completed but app bundle was not found at $BUILD_OUTPUT_APP"
    exit 1
fi

mkdir -p "$RELEASES_DIR"
rm -rf "$SIGNED_APP_PATH"
ditto "$BUILD_OUTPUT_APP" "$SIGNED_APP_PATH"
log_success "Copied app bundle to $SIGNED_APP_PATH"

log_step "4. Signing with Developer ID"

sign_nested_code "$SIGNED_APP_PATH"
codesign --force --sign "$IDENTITY" \
    --entitlements "$RELEASE_ENTITLEMENTS" \
    --options runtime \
    --timestamp \
    "$SIGNED_APP_PATH"
codesign --verify --deep --strict --verbose=2 "$SIGNED_APP_PATH" >&2
log_success "Signed app bundle"

log_step "5. Creating DMG"

create_dmg "$SIGNED_APP_PATH" "$DMG_PATH"
log_success "Created $DMG_PATH"

if [[ "$NO_NOTARIZE" == "false" ]]; then
    log_step "6. Notarizing release artifacts"
    notarize_and_staple "$SIGNED_APP_PATH" "$DMG_PATH"
else
    log_step "6. Skipping notarization"
    log_warning "DMG is signed but not notarized"
fi

if [[ "$NO_UPLOAD" == "false" ]]; then
    log_step "7. Publishing GitHub release"

    if gh release view "$TAG_NAME" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        log_error "GitHub release already exists for $TAG_NAME"
        exit 1
    fi

    if [[ "$NO_TAG" == "false" ]]; then
        if ! git rev-parse --verify --quiet "refs/tags/$TAG_NAME" >/dev/null; then
            git tag -a "$TAG_NAME" -m "Release $BUILD_NAME"
            log_success "Created local git tag: $TAG_NAME"
        else
            log_info "Local git tag already exists: $TAG_NAME"
        fi

        if git ls-remote --exit-code --tags origin "refs/tags/$TAG_NAME" >/dev/null 2>&1; then
            log_info "Remote git tag already exists: $TAG_NAME"
        else
            git push origin "refs/tags/$TAG_NAME:refs/tags/$TAG_NAME" >&2
            log_success "Pushed git tag: $TAG_NAME"
        fi
    fi

    RELEASE_BODY=$(cat <<EOF
## What's New

$RELEASE_NOTES

## Downloads

- \`$(basename "$DMG_PATH")\`

## System Requirements

- macOS 10.15 or later
EOF
)

    if [[ "$NO_TAG" == "false" ]]; then
        gh release create "$TAG_NAME" \
            --repo "$GITHUB_REPO" \
            --title "$APP_NAME $BUILD_NAME" \
            --notes "$RELEASE_BODY" \
            --verify-tag \
            "$DMG_PATH"
    else
        gh release create "$TAG_NAME" \
            --repo "$GITHUB_REPO" \
            --title "$APP_NAME $BUILD_NAME" \
            --notes "$RELEASE_BODY" \
            --target "$(git rev-parse HEAD)" \
            "$DMG_PATH"
    fi

    log_success "GitHub release created: $RELEASE_URL"

    git push origin HEAD >&2 || log_warning "Push failed. Push the current branch manually."
fi

log_step "Release complete"
log_success "App: $SIGNED_APP_PATH"
log_success "DMG: $DMG_PATH"

if [[ "$NO_UPLOAD" == "false" ]]; then
    log_success "Release: $RELEASE_URL"
fi
