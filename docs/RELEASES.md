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

## Notarized release outline

Once Developer ID credentials are available:

```bash
# Build app
scripts/install-echopilot-app.sh

# Sign with Developer ID Application identity instead of ad-hoc/dev signing.
codesign --force --deep --options runtime \
  --entitlements Xcode/EchoPilot/EchoPilot.entitlements \
  --sign "Developer ID Application: <Team Name> (<TEAMID>)" \
  /Applications/EchoPilot.app

# Create DMG using create-dmg or hdiutil.
# Submit for notarization.
xcrun notarytool submit EchoPilot.dmg --keychain-profile <profile> --wait
xcrun stapler staple EchoPilot.dmg
```

## GitHub Actions

A full CI release workflow should run on `macos-latest`, but signing/notarization requires repository secrets:

- `APPLE_TEAM_ID`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD` or App Store Connect API key
- Developer ID certificate and password, if signing in CI

Until those secrets exist, keep the automated workflow limited to source checks and local/manual release builds.
