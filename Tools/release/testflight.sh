#!/bin/sh
# Build Overeasy for TestFlight and hand it to App Store Connect.
#
# Everything before the upload is repeatable and destroys nothing, so the
# safe way to use this is `--validate-only` first: it runs the same checks
# Apple runs on receipt, without spending a build number.
set -eu
umask 077

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: testflight.sh [--build NUMBER] [--validate-only] [--archive-only]

Credentials come from the environment. An App Store Connect API key with the
App Manager role is needed to upload; create one under Users and Access ->
Integrations, and keep the .p8 out of the repository.

    LADLE_ASC_KEY_ID      the key's ten-character identifier
    LADLE_ASC_ISSUER_ID   the issuer UUID shown above the key list
    LADLE_ASC_KEY_PATH    path to AuthKey_<KEY_ID>.p8
                          (default: ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8)

The build number defaults to today's date with a .1 suffix. Pass --build to
set it yourself; App Store Connect rejects a build number it has already seen
for this marketing version.
USAGE
}

BUILD_NUMBER=""
VALIDATE_ONLY=no
ARCHIVE_ONLY=no

while [ "$#" -gt 0 ]; do
    case "$1" in
        --build) [ "$#" -ge 2 ] || die "--build needs a value"; BUILD_NUMBER="$2"; shift 2 ;;
        --validate-only) VALIDATE_ONLY=yes; shift ;;
        --archive-only) ARCHIVE_ONLY=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BUILD_DIR="$ROOT/build/release"
ARCHIVE="$BUILD_DIR/Ladle.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
IPA="$EXPORT_DIR/Ladle.ipa"

[ -n "$BUILD_NUMBER" ] || BUILD_NUMBER="$(date +%Y%m%d).1"

if [ "$ARCHIVE_ONLY" = no ]; then
    KEY_ID="${LADLE_ASC_KEY_ID:-}"
    ISSUER_ID="${LADLE_ASC_ISSUER_ID:-}"
    [ -n "$KEY_ID" ] || die "set LADLE_ASC_KEY_ID (see --help)"
    [ -n "$ISSUER_ID" ] || die "set LADLE_ASC_ISSUER_ID (see --help)"
    KEY_PATH="${LADLE_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8}"
    [ -f "$KEY_PATH" ] || die "no API key at $KEY_PATH"
    # altool takes a key id rather than a path, and looks the file up in a
    # handful of fixed directories. This lets the key live wherever it likes.
    API_PRIVATE_KEYS_DIR=$(cd "$(dirname "$KEY_PATH")" && pwd)
    export API_PRIVATE_KEYS_DIR
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

printf 'Archiving Overeasy at build %s\n' "$BUILD_NUMBER"
xcodebuild archive \
    -project "$ROOT/Ladle.xcodeproj" \
    -scheme Ladle \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -allowProvisioningUpdates

[ "$ARCHIVE_ONLY" = no ] || { printf 'Archive at %s\n' "$ARCHIVE"; exit 0; }

printf 'Exporting a signed .ipa\n'
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$ROOT/Config/ExportOptions.plist" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_PATH" \
    -authenticationKeyID "$KEY_ID" \
    -authenticationKeyIssuerID "$ISSUER_ID"

[ -f "$IPA" ] || die "export produced no .ipa in $EXPORT_DIR"

printf 'Validating with App Store Connect\n'
xcrun altool --validate-app \
    --file "$IPA" \
    --type ios \
    --apiKey "$KEY_ID" \
    --apiIssuer "$ISSUER_ID"

if [ "$VALIDATE_ONLY" = yes ]; then
    printf 'Validated. Nothing was uploaded.\n'
    exit 0
fi

printf 'Uploading\n'
xcrun altool --upload-app \
    --file "$IPA" \
    --type ios \
    --apiKey "$KEY_ID" \
    --apiIssuer "$ISSUER_ID"

printf 'Uploaded build %s. It appears in TestFlight once Apple finishes processing.\n' "$BUILD_NUMBER"
