# Signed macOS releases

The Release workflow runs on a pushed `vMAJOR.MINOR.PATCH` tag. It tests the project, builds the existing app bundle, signs with Developer ID and Hardened Runtime plus a secure timestamp, submits to Apple, requires an Accepted result, staples and validates the ticket, checks Gatekeeper, then creates the final ZIP and SHA-256 file. A failure prevents publication. Re-running the same tag replaces its release assets. ZIP filenames and bundle identifiers remain unchanged.

## One-time repository setup

Open **Settings → Secrets and variables → Actions → New repository secret** in each repository. Add these names to BOTH repositories (the same Apple credentials can be used for both):

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 of an exported **Developer ID Application** `.p12` containing the certificate AND its private key. |
| `APPLE_CERTIFICATE_PASSWORD` | The password chosen when exporting the `.p12`. |
| `APPLE_SIGNING_IDENTITY` | Full identity, exactly `Developer ID Application: Your Name (TEAMID)`, as shown by `security find-identity -v -p codesigning`. |
| `APPLE_TEAM_ID` | Your Apple Developer Team ID. The script verifies that the signed app matches this team. |
| `ASC_KEY_ID` | App Store Connect **Team API Key** ID. |
| `ASC_ISSUER_ID` | Issuer ID for that Team API Key (a UUID, not the Developer Team ID). |
| `ASC_PRIVATE_KEY_BASE64` | Base64 of the downloaded `AuthKey_KEYID.p8` private key. |

In App Store Connect, an authorized account holder/admin can enable API access and create a Team key under **Users and Access → Integrations → App Store Connect API → Team Keys**. Use a key with the Developer role or another role Apple permits for notarization. Download its `.p8` when created; Apple only allows the private key to be downloaded once. This workflow explicitly uses a **Team** key with an issuer; individual keys use different authentication parameters and are not supported by this configuration. No App Store listing, app-specific Apple Account password, provisioning profile, or Developer ID Installer certificate is needed for these existing app bundles.

On your own Mac, copy each encoded file directly to the clipboard, then paste into the corresponding GitHub secret:

```sh
base64 -i "/absolute/path/DeveloperID.p12" | pbcopy
# Paste into APPLE_CERTIFICATE_P12_BASE64 before running the next command.
base64 -i "/absolute/path/AuthKey_KEYID.p8" | pbcopy
# Paste into ASC_PRIVATE_KEY_BASE64, then clear the clipboard:
printf '' | pbcopy
```

Base64 is encoding, not encryption. Keep original private keys outside the repository and never paste them into chat or logs. `.gitignore` excludes common private-key filenames as a safeguard. The workflow creates a random temporary keychain password, so no keychain-password secret is needed. It removes the temporary keychain, certificate and API key on success or failure. Do not enable shell tracing. Restrict who can push release tags: tag code runs with signing credentials. These scripts are intended for GitHub-hosted disposable runners.

The automatic `GITHUB_TOKEN` publishes releases with `contents: write`; no personal access token is required for releases. Ensure GitHub Actions is enabled and repository/organization policy permits this permission.

## Publish after reviewing and merging these changes

Move the entries under `## [Unreleased]` in `CHANGELOG.md` into a new `## [x.y.z] - YYYY-MM-DD` section and add its compare link at the bottom. The workflow uses that section as the release notes; if it is missing it warns and falls back to GitHub-generated notes.

Choose a NEW version. The following is an example only; do not reuse an existing release tag:

```sh
git tag v1.2.3
git push origin v1.2.3
```

The tag must point to a commit containing this workflow and the signing script. Only stable three-part numeric versions are supported because the bundle version must be numeric. The manual `workflow_dispatch` trigger only runs when a `v…` tag is selected (or supplied as the ref through GitHub CLI); branch runs are skipped. The workflow must be on the default branch before GitHub shows its manual Run button.

Download `FilePicker-1.2.3.zip` and its `.sha256` file from the GitHub Release. Extract the ZIP, then verify on another Mac:

```sh
shasum -a 256 -c FilePicker-1.2.3.zip.sha256
xcrun stapler validate "FilePicker.app"
codesign --verify --deep --strict --verbose=2 "FilePicker.app"
spctl --assess --type execute --verbose=2 "FilePicker.app"
```

Launch the app normally from Finder and check its features. Accessibility and any other macOS privacy permissions still require user consent. The workflow retains the existing single-runner architecture; it does not add a universal Intel/Apple Silicon build.

## Troubleshooting

Missing secrets stop the signing step before release publication. Check `.p12` includes the private key, its password, the exact identity and matching team, API key role/access and issuer. Apple rejection logs are printed on a failed submission. A 45-minute notarization timeout stops publication; check the submission ID with Apple before rerunning. Initial submissions can take longer. Never publish the pre-stapling submission ZIP.

The script signs the current single-executable bundle. If embedded frameworks, helpers, plug-ins or XPC services are added later, sign those from the inside out before signing the outer bundle. No extra entitlements are currently introduced. Test app behavior under Hardened Runtime on the first signed release.

References: [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Apple command-line workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [GitHub certificate secrets](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
