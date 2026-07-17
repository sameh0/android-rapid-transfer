#!/usr/bin/env bash

# Installs, and afterwards removes, the release credentials a CI run was given.
#
#   Scripts/ci-credentials.sh setup
#   Scripts/ci-credentials.sh cleanup
#
# setup, from environment variables (GitHub secrets), each part optional:
#
#   DEVELOPER_ID_P12_BASE64    base64 of the exported Developer ID Application
#   DEVELOPER_ID_P12_PASSWORD  certificate (.p12) and its export password:
#                              imported into a temporary keychain added to the
#                              search list, so codesign finds the identity.
#                              DEVELOPER_ID_APP and TEAM_ID are exported from
#                              the certificate unless already set.
#   NOTARY_API_KEY_P8_BASE64   base64 of an App Store Connect API key (.p8):
#                              written to a private file, exported as
#                              NOTARY_API_KEY_PATH for Scripts/notarize.sh.
#
# A part whose secrets are missing is skipped with a note saying which secrets
# would enable it; no secrets at all is a successful no-op. Exports go to
# $GITHUB_ENV (later steps of the job) or, off GitHub Actions, are printed as
# `export` lines. cleanup deletes the keychain and key file and restores the
# keychain search list; it is safe to run whether or not setup ran or finished.
#
# setup changes the user's keychain search list, so it refuses to run outside
# CI (CI=true) unless ART_ALLOW_LOCAL_KEYCHAIN=1.

set -euo pipefail

MODE=${1:-}
[[ $# -eq 1 && ( "$MODE" == setup || "$MODE" == cleanup ) ]] || {
    echo "Usage: $0 setup|cleanup" >&2
    exit 2
}

WORK_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/art-ci-credentials"
KEYCHAIN="$WORK_DIR/art-signing.keychain-db"
API_KEY_FILE="$WORK_DIR/AuthKey.p8"
SECURITY=/usr/bin/security
# Apple's Developer ID intermediate (G2), which issues current certificates.
DEVELOPER_ID_INTERMEDIATE_URL=${DEVELOPER_ID_INTERMEDIATE_URL:-https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer}

note() { echo "ci-credentials: $*"; }
fail() {
    echo "ERROR: $*" >&2
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=Release credentials::$*"
    exit 1
}

export_variable() {
    local name=$1 value=$2
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "$name=$value" >>"$GITHUB_ENV"
    else
        printf 'export %s=%q\n' "$name" "$value"
    fi
}

mask() {
    [[ -n "${GITHUB_ACTIONS:-}" && -n "$1" ]] && echo "::add-mask::$1"
    return 0
}

# Decodes $1 into the private file $2; $3 names the secret in errors. macOS's
# base64 ignores line breaks and succeeds on garbage, so callers also check
# what comes out.
decode_base64() {
    (umask 077 && printf '%s' "$1" | /usr/bin/base64 --decode >"$2") \
        || fail "Could not decode $3."
    [[ -s "$2" ]] || fail "$3 decodes to nothing; is it base64?"
}

# The user search list, one path per line, without this script's keychain.
search_list_without_ours() {
    "$SECURITY" list-keychains -d user \
        | /usr/bin/sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/' \
        | /usr/bin/grep -vxF "$KEYCHAIN" || true
}

cleanup() {
    if [[ -e "$KEYCHAIN" ]] || "$SECURITY" list-keychains -d user | /usr/bin/grep -qF "$KEYCHAIN"; then
        local -a keep=()
        local line
        while IFS= read -r line; do
            [[ -n "$line" ]] && keep+=("$line")
        done < <(search_list_without_ours)
        "$SECURITY" list-keychains -d user -s ${keep[@]+"${keep[@]}"} || true
        "$SECURITY" delete-keychain "$KEYCHAIN" 2>/dev/null || true
        note "removed the temporary signing keychain."
    fi
    /bin/rm -rf "$WORK_DIR"
    note "cleanup done."
}

if [[ "$MODE" == cleanup ]]; then
    cleanup
    exit 0
fi

if [[ "${CI:-}" != true && "${ART_ALLOW_LOCAL_KEYCHAIN:-0}" != 1 ]]; then
    fail "setup edits the keychain search list; run it in CI, or set ART_ALLOW_LOCAL_KEYCHAIN=1."
fi

/bin/mkdir -p "$WORK_DIR"
/bin/chmod 700 "$WORK_DIR"

# --- Developer ID certificate -------------------------------------------------
if [[ -z "${DEVELOPER_ID_P12_BASE64:-}" ]]; then
    note "Developer ID signing: skipped (no DEVELOPER_ID_P12_BASE64 / DEVELOPER_ID_P12_PASSWORD secrets); the build will be ad-hoc signed."
else
    [[ -n "${DEVELOPER_ID_P12_PASSWORD:-}" ]] \
        || fail "DEVELOPER_ID_P12_BASE64 is set but DEVELOPER_ID_P12_PASSWORD is not."
    P12="$WORK_DIR/developer-id.p12"
    KEYCHAIN_PASSWORD=$(/usr/bin/openssl rand -base64 32)
    mask "$KEYCHAIN_PASSWORD"
    decode_base64 "$DEVELOPER_ID_P12_BASE64" "$P12" DEVELOPER_ID_P12_BASE64

    "$SECURITY" delete-keychain "$KEYCHAIN" 2>/dev/null || true
    "$SECURITY" create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    "$SECURITY" set-keychain-settings -lut 21600 "$KEYCHAIN"
    "$SECURITY" unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    "$SECURITY" import "$P12" -k "$KEYCHAIN" -f pkcs12 -P "$DEVELOPER_ID_P12_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null \
        || { /bin/rm -f "$P12"; fail "Could not import the Developer ID certificate (wrong DEVELOPER_ID_P12_PASSWORD?)."; }
    /bin/rm -f "$P12"
    # A .p12 exported from Keychain Access usually lacks the intermediate
    # certificate, without which the identity is not valid for codesign.
    if /usr/bin/curl -fsSL --retry 3 "$DEVELOPER_ID_INTERMEDIATE_URL" -o "$WORK_DIR/intermediate.cer"; then
        "$SECURITY" import "$WORK_DIR/intermediate.cer" -k "$KEYCHAIN" >/dev/null 2>&1 || true
    else
        note "could not download $DEVELOPER_ID_INTERMEDIATE_URL; relying on the runner's certificates."
    fi
    # Lets codesign use the key without a GUI prompt.
    "$SECURITY" set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

    existing=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && existing+=("$line")
    done < <(search_list_without_ours)
    "$SECURITY" list-keychains -d user -s "$KEYCHAIN" ${existing[@]+"${existing[@]}"}

    identity=$("$SECURITY" find-identity -v -p codesigning "$KEYCHAIN" \
        | /usr/bin/sed -nE 's/^[[:space:]]*[0-9]+\) [0-9A-F]{40} "(Developer ID Application: .*)"$/\1/p' \
        | /usr/bin/head -n 1)
    if [[ -z "$identity" ]]; then
        echo "Identities in the imported certificate:" >&2
        "$SECURITY" find-identity -p codesigning "$KEYCHAIN" >&2 || true
        fail "The .p12 holds no valid 'Developer ID Application' identity (an Apple Development or Distribution certificate will not do; an untrusted chain shows above as CSSMERR_TP_NOT_TRUSTED)."
    fi
    DEVELOPER_ID_APP=${DEVELOPER_ID_APP:-$identity}
    export_variable DEVELOPER_ID_APP "$DEVELOPER_ID_APP"
    if [[ -z "${TEAM_ID:-}" && "$DEVELOPER_ID_APP" =~ \(([A-Z0-9]{10})\)$ ]]; then
        TEAM_ID=${BASH_REMATCH[1]}
    fi
    [[ -n "${TEAM_ID:-}" ]] && export_variable TEAM_ID "$TEAM_ID"
    note "Developer ID signing: imported '$DEVELOPER_ID_APP' into a temporary keychain."
fi

# --- App Store Connect API key (notarization) ---------------------------------
if [[ -z "${NOTARY_API_KEY_P8_BASE64:-}" ]]; then
    note "Notarization API key: not provided (NOTARY_API_KEY_P8_BASE64); notarization can still use APPLE_ID / TEAM_ID / APP_PASSWORD."
else
    decode_base64 "$NOTARY_API_KEY_P8_BASE64" "$API_KEY_FILE" NOTARY_API_KEY_P8_BASE64
    /usr/bin/grep -q 'BEGIN PRIVATE KEY' "$API_KEY_FILE" \
        || fail "NOTARY_API_KEY_P8_BASE64 does not decode to a .p8 private key."
    export_variable NOTARY_API_KEY_PATH "$API_KEY_FILE"
    note "Notarization API key: written to a private temporary file."
fi
