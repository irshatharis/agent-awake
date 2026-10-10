# Releasing Agent Awake

## Preview distribution

The current public preview is v0.1.1. It is ad-hoc signed, not Developer ID signed or
Apple-notarized. The website, release notes, and README must state that beside the
install instructions. Do not describe it as a notarized release.

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in
   `Resources/Info.plist`. Settings reads its displayed version from the bundle.
2. Run `scripts/package-release.sh`. It runs the deterministic checks, compiles arm64
   and x86_64 separately, merges all three executables with `lipo`, signs the sealed
   app, verifies signatures, and creates the ZIP and `SHA256SUMS.txt` in `dist/`.
   It works with Command Line Tools; full Xcode is not required.
3. Extract the ZIP to a temporary directory and verify its deep code signature and
   both architectures. Never replace a currently installed app as part of packaging.
4. Commit and push the exact source used to build the artifact. Create a GitHub
   **prerelease** tagged with the version, attaching the ZIP and checksum. Include
   opening instructions, setup, known detection limits, and test boundaries.
5. Update the pinned release links in `README.md` and `website/index.html`.
   Prereleases are excluded from GitHub's `/releases/latest` resolution, so use the
   explicit tag URL. Do not overwrite an existing release asset with different bytes.

Example publication after validation:

```sh
gh release create v0.1.1 \
  dist/Agent-Awake-0.1.1-macos-universal.zip dist/SHA256SUMS.txt \
  --repo irshatharis/agent-awake --target <pushed-commit-sha> \
  --prerelease --title 'Agent Awake 0.1.1 — macOS preview' \
  --notes-file <release-notes-file>
```

Physical checks have been performed on Apple Silicon. A universal binary is not proof
of Intel hardware or macOS 14 behavior. Preserve the distinction in public copy.

## Developer ID and notarization

A smoother public installation requires an Apple Developer account, a Developer ID
Application signing identity, and notarization credentials. None are stored in this
repository. Keep signing assets and credentials outside source control.

Build with `SIGN_IDENTITY='Developer ID Application: …' UNIVERSAL=1 scripts/build-app.sh`.
Submit a ZIP of the signed app to Apple's notary service using a configured Keychain
profile, wait for acceptance, staple the ticket to the app, validate it, then recreate
the public ZIP and checksum from the stapled bundle. Signing alone is not notarization.
Verify with `codesign --verify --deep --strict` and Gatekeeper assessment before
publishing. See [Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Website

The buildless landing-page source lives in `website/`. Preview it with:

```sh
python3 -m http.server 4173 --directory website --bind 127.0.0.1
```

The Sites deployment checkout is isolated under `.build/site/` so its managed source
repository does not become a nested Git submodule in this project. Copy `website/`
assets into that checkout's `dist/`, preserve its `.openai/hosting.json` project ID,
and publish using the Sites source workflow. The site contains no analytics, external
font dependencies, account system, or app-data integration. Mac binaries are hosted
as versioned GitHub release assets.
