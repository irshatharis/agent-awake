# Releasing Agent Awake

## DMG releases

The current preview is v0.1.5. It is ad-hoc signed and not Apple-notarized.
Keep that status visible in the README, site, and release notes until a notarized
release is published. A DMG alone does not remove Gatekeeper warnings.

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in
   `Resources/Info.plist`.
2. Run `PREVIEW=1 scripts/package-release.sh` for an unnotarized preview, or use
   the notarized release command below. The script runs checks, builds both
   architectures, signs the app, and creates a DMG with an Applications shortcut
   and `SHA256SUMS.txt` in `dist/`. It does not create a ZIP.
3. Mount the DMG read-only, copy the app to a temporary directory, and verify its
   deep code signature and both architectures. Do not replace an installed app
   while testing the package. Test a browser download on a Mac before release.
4. Commit and push the exact source used to build it. Publish a new GitHub release
   with the DMG and checksum. Keep unnotarized builds marked as prereleases.
5. Update the versioned links in `README.md` and `website/index.html` together.
   Prereleases are excluded from `/releases/latest`. Do not overwrite published
   assets with different bytes.

```sh
gh release create v0.1.5 \
  dist/Agent-Awake-0.1.5-macos-universal.dmg dist/SHA256SUMS.txt \
  --repo irshatharis/agent-awake --target <pushed-commit-sha> \
  --prerelease --title 'Agent Awake 0.1.5: macOS preview' \
  --notes-file <release-notes-file>
```

Physical checks have been performed on Apple Silicon. Intel hardware and macOS 14
have not been physically tested. See [verification](VERIFICATION.md).

## Developer ID and notarization

To remove the unverified-developer warning, enroll in the Apple Developer Program
and create a **Developer ID Application** certificate. Install it with its private
key in the release Mac's Keychain. Never commit signing assets or credentials.

Store notarization credentials in a Keychain profile. This command prompts for
the Apple Account, team ID, and app-specific password:

```sh
xcrun notarytool store-credentials AgentAwake
```

Then build the release:

```sh
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE=AgentAwake scripts/package-release.sh
```

The release script requires both settings unless `PREVIEW=1` is explicit. It:

- Signs the app and both helpers with hardened runtime and secure timestamps.
- Submits a temporary DMG to Apple, waits for acceptance, and staples the app ticket.
- Creates the final DMG with the stapled app and an Applications shortcut.
- Signs and notarizes the DMG, then staples its ticket.
- Validates both tickets and Gatekeeper assessments before generating the checksum.

If Apple rejects a submission, packaging fails and saves the notary log in `dist/`.
Do not publish a rejected build. Signing alone is not notarization.
See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Website

The site is hosted at [irshatharis.github.io/agent-awake](https://irshatharis.github.io/agent-awake/).
GitHub Pages must use **GitHub Actions** as its publishing source. The
`.github/workflows/pages.yml` workflow deploys `website/` on changes pushed to `main`
and can also be run manually. Binaries are hosted on GitHub releases.

```sh
python3 -m http.server 4173 --directory website --bind 127.0.0.1
```
