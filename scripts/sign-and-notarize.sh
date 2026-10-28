#!/bin/bash
# Run only on a disposable macOS CI runner. Never enable shell tracing here.
set -euo pipefail
umask 077
start_ts=$(date +%s)
log() { printf '[%s +%03ds] %s\n' "$(date -u +%H:%M:%S)" "$(( $(date +%s) - start_ts ))" "$*"; }
group() { echo "::group::$*"; log "$*"; }
endgroup() { echo "::endgroup::"; }
: "${RUNNER_TEMP:?Set RUNNER_TEMP to an existing writable temporary directory}" "${APP_PATH:?}" "${ZIP_PATH:?}" "${APPLE_CERTIFICATE_P12_BASE64:?}" "${APPLE_CERTIFICATE_PASSWORD:?}"
: "${APPLE_SIGNING_IDENTITY:?}" "${APPLE_TEAM_ID:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_PRIVATE_KEY_BASE64:?}"
[[ "$APPLE_SIGNING_IDENTITY" == "Developer ID Application: "* ]] || { echo 'Expected a Developer ID Application identity'; exit 1; }
group "Prepare keychain"
secret_dir=$(mktemp -d "$RUNNER_TEMP/apple-release.XXXXXX")
keychain="$secret_dir/signing.keychain-db"
keychain_password=$(openssl rand -hex 32)
original_keychains=()
while IFS= read -r item; do
  item="${item#*\"}"; item="${item%\"*}"
  original_keychains+=("$item")
done < <(security list-keychains -d user)
cleanup() {
  security list-keychains -d user -s "${original_keychains[@]}" || true
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -rf "$secret_dir"
}
trap cleanup EXIT
printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$secret_dir/certificate.p12"
printf '%s' "$ASC_PRIVATE_KEY_BASE64" | base64 --decode > "$secret_dir/AuthKey.p8"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$secret_dir/certificate.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security -f pkcs12 -k "$keychain" >/dev/null
security find-identity -v -p codesigning "$keychain" | grep -Fq "$APPLE_SIGNING_IDENTITY" || { echo 'Signing identity (certificate + private key) not found after import'; exit 1; }
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
log "identity imported into temporary keychain"
endgroup
group "Codesign $APP_PATH"
# These bundles contain one executable and no nested frameworks or helpers.
codesign --force --timestamp --options runtime --keychain "$keychain" --sign "$APPLE_SIGNING_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --verbose=4 "$APP_PATH" 2> "$secret_dir/signature.txt"
grep -Fqx "TeamIdentifier=$APPLE_TEAM_ID" "$secret_dir/signature.txt"
grep -q 'flags=.*runtime' "$secret_dir/signature.txt"
log "signed and verified (team $APPLE_TEAM_ID, hardened runtime)"
endgroup
group "Notarize"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$secret_dir/submission.zip"
log "submission zip: $(du -h "$secret_dir/submission.zip" | cut -f1)"
xcrun notarytool store-credentials release-notary --keychain "$keychain" \
  --key "$secret_dir/AuthKey.p8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >/dev/null
log "credentials stored; submitting"
json_field() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception: print("")' "$1" "$2"; }
# Submit without --wait so progress is visible, then poll.
submit_status=0
xcrun notarytool submit "$secret_dir/submission.zip" --keychain "$keychain" \
  --keychain-profile release-notary --output-format json \
  > "$secret_dir/submit.json" 2> "$secret_dir/submit.err" || submit_status=$?
submission_id=$(json_field "$secret_dir/submit.json" id)
if [[ "$submit_status" != 0 || -z "$submission_id" ]]; then
  log "submit failed (exit $submit_status)"
  cat "$secret_dir/submit.err" || true
  exit 1
fi
log "submitted: $submission_id (upload took $(( $(date +%s) - start_ts ))s total so far)"
deadline=$(( $(date +%s) + 45 * 60 ))
status=""
poll_failures=0
while :; do
  if xcrun notarytool info "$submission_id" --keychain "$keychain" --keychain-profile release-notary \
       --output-format json > "$secret_dir/info.json" 2> "$secret_dir/info.err"; then
    poll_failures=0
    status=$(json_field "$secret_dir/info.json" status)
    log "status: ${status:-unknown}"
    case "$status" in
      Accepted|Invalid|Rejected) break ;;
    esac
  else
    poll_failures=$((poll_failures + 1))
    log "poll failed ($poll_failures): $(tr '\n' ' ' < "$secret_dir/info.err")"
    [[ $poll_failures -lt 10 ]] || { log "giving up polling"; break; }
  fi
  if (( $(date +%s) >= deadline )); then log "timed out after 45m with status '${status:-unknown}'"; break; fi
  sleep 30
done
if [[ "$status" != Accepted ]]; then
  log "notarization did not complete successfully: ${status:-unknown} (submission $submission_id)"
  xcrun notarytool log "$submission_id" --keychain "$keychain" --keychain-profile release-notary || true
  exit 1
fi
log "accepted"
endgroup
group "Staple and package"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
mkdir -p "$(dirname "$ZIP_PATH")"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
(cd "$(dirname "$ZIP_PATH")" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256")
log "packaged $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
endgroup
