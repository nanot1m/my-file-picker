#!/bin/bash
# Run only on a disposable macOS CI runner. Never enable shell tracing here.
set -euo pipefail
umask 077
: "${APP_PATH:?}" "${ZIP_PATH:?}" "${APPLE_CERTIFICATE_P12_BASE64:?}" "${APPLE_CERTIFICATE_PASSWORD:?}"
: "${APPLE_SIGNING_IDENTITY:?}" "${APPLE_TEAM_ID:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_PRIVATE_KEY_BASE64:?}"
[[ "$APPLE_SIGNING_IDENTITY" == "Developer ID Application: "* ]] || { echo 'Expected a Developer ID Application identity'; exit 1; }
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
security import "$secret_dir/certificate.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security -t cert -f pkcs12 -k "$keychain" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
# These bundles contain one executable and no nested frameworks or helpers.
codesign --force --timestamp --options runtime --keychain "$keychain" --sign "$APPLE_SIGNING_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --verbose=4 "$APP_PATH" 2> "$secret_dir/signature.txt"
grep -Fqx "TeamIdentifier=$APPLE_TEAM_ID" "$secret_dir/signature.txt"
grep -q 'flags=.*runtime' "$secret_dir/signature.txt"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$secret_dir/submission.zip"
xcrun notarytool store-credentials release-notary --keychain "$keychain" \
  --key "$secret_dir/AuthKey.p8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >/dev/null
# Save the response even on rejection, then explicitly require Accepted.
submit_status=0
xcrun notarytool submit "$secret_dir/submission.zip" --keychain "$keychain" \
  --keychain-profile release-notary --wait --timeout 45m --output-format json \
  > "$secret_dir/result.json" || submit_status=$?
status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$secret_dir/result.json")
if [[ "$submit_status" != 0 || "$status" != Accepted ]]; then
  submission_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$secret_dir/result.json")
  echo "Notarization did not complete successfully: $status (submission $submission_id)"
  if [[ -n "$submission_id" ]]; then
    xcrun notarytool log "$submission_id" --keychain "$keychain" --keychain-profile release-notary || true
  fi
  exit 1
fi
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
mkdir -p "$(dirname "$ZIP_PATH")"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
(cd "$(dirname "$ZIP_PATH")" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256")
