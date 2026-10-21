# Releasing

## Making a release

1. Set the version in **both** `core/Cargo.toml` (`[workspace.package] version`) and `app/project.yml` (`CFBundleShortVersionString`, and bump `CFBundleVersion`).
2. Move the changes under a `## [x.y.z] - YYYY-MM-DD` heading in `CHANGELOG.md`. The release notes are generated from it.
3. Run `make lint test`, then `make release`. This creates the following in `dist/`:
   - `ClawTank-x.y.z-arm64.dmg`: the app plus an /Applications link
   - `SHA256SUMS`
   - `RELEASE_NOTES.md`: the changelog section plus install steps

   The script refuses to run if the versions differ or the changelog section is missing. It verifies the DMG (integrity, layout, deep code signature, bundled `clawtank-mcp`).

   Release builds go to `build/release/`, so they never replace your dev-signed `app/build` app and its permissions.
4. Create a **draft** GitHub Release and review it before publishing:
   ```sh
   gh release create vX.Y.Z dist/ClawTank-*.dmg dist/SHA256SUMS --draft \
     --title "ClawTank X.Y.Z" --notes-file dist/RELEASE_NOTES.md
   ```
   Add `--prerelease` for betas.

## Signing and notarization (Developer ID)

Without credentials, builds are ad-hoc signed: users do the one-time "Open Anyway" step, and macOS asks for permissions again after each update. With an Apple Developer account:

```sh
xcrun notarytool store-credentials clawtank-notary --apple-id … --team-id … --password <app-specific>
export CLAWTANK_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export CLAWTANK_NOTARY_PROFILE=clawtank-notary
make release
```

`scripts/release.sh` signs `clawtank-mcp` and then the app with the hardened runtime and a timestamp, signs the DMG, notarizes it and staples it. **This path hasn't been run yet** (no Developer ID so far; ADR-024). Test it before relying on it.

## Updates

There's no in-app update feed yet. Sparkle (or similar) is planned once releases are Developer ID-signed, because an update framework on unsigned builds can't give users a meaningful integrity guarantee beyond the published checksum (ADR-024).
