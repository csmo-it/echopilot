# Build and Release Strategy

## Recommended distribution path

For early public builds, use **GitHub Releases** with a signed `.app` zipped or packaged as a `.dmg`.

Recommended stages:

1. **Developer/local build**
   - Build and install locally via `scripts/install-echopilot-app.sh`.
   - Good for rapid testing and internal validation.

2. **Public beta release**
   - Publish versioned builds on GitHub Releases.
   - Attach either:
     - `EchoPilot.zip` containing `EchoPilot.app`, or
     - `EchoPilot.dmg` for a more native install experience.
   - Include release notes with known limitations and macOS permission instructions.

3. **Signed + notarized release**
   - Use an Apple Developer ID Application certificate.
   - Notarize with Apple notarytool.
   - Staple the notarization ticket.
   - Attach the notarized `.dmg` to GitHub Releases.

4. **Auto-update later**
   - Add Sparkle for in-app update checks.
   - Host Sparkle appcast and builds from GitHub Releases.
   - Keep auto-update optional until signing/notarization is stable.

## Why GitHub Releases first?

- No backend required.
- Users can download stable versions instead of building from source.
- Works before a full auto-update system exists.
- Release assets can later become the source for Sparkle updates.

## Manual release flow

On a macOS machine with Xcode:

```bash
git pull
scripts/package-echopilot-release.sh
```

This creates `dist/EchoPilot-<version>.zip`. Create a GitHub Release and attach that ZIP.

For local signed testing before packaging, use:

```bash
scripts/install-echopilot-app.sh
open /Applications/EchoPilot.app
```

## Signed + notarized release flow

Use this for public release assets when you have a paid Apple Developer account. This signs with a **Developer ID Application** certificate, submits the DMG to Apple notarization, and staples the notarization ticket.

### 1. Create/download the Developer ID Application certificate

On the Mac that builds releases:

```bash
Xcode → Settings → Accounts → Manage Certificates… → + → Developer ID Application
```

Verify it exists and has a private key:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Create a notarytool keychain profile once

Use an app-specific password for your Apple ID, or an App Store Connect API key. Apple ID flow:

```bash
xcrun notarytool store-credentials echopilot-notary \
  --apple-id "YOUR_APPLE_ID@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

This stores credentials in your local Keychain; do not commit passwords or certificates.

### 3. Build, sign, notarize, staple

```bash
git pull
NOTARY_PROFILE=echopilot-notary scripts/package-echopilot-notarized.sh
```

Outputs:

```text
dist/EchoPilot-<version>.dmg
dist/EchoPilot-<version>.zip
```

Upload the DMG to the GitHub Release. Prefer the DMG for public users because it carries the stapled notarization ticket.

Optional local config file, ignored by Git:

```bash
cat > .echopilot-signing.env <<'EOF'
NOTARY_PROFILE=echopilot-notary
# Optional if auto-detection finds the wrong certificate:
# DEVELOPER_ID_APPLICATION_IDENTITY="Developer ID Application: Your Name (TEAMID)"
EOF
```

## GitHub Actions

A full CI release workflow should run on `macos-latest`, but signing/notarization requires repository secrets:

- `APPLE_TEAM_ID`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD` or App Store Connect API key
- Developer ID certificate and password, if signing in CI

Until those secrets exist, keep the automated workflow limited to source checks and local/manual release builds.
