# Releasing

A release is built by `.github/workflows/release.yml`.

- **Publish:** push a tag that starts with `v`, for example `git tag v0.1.0 && git push origin v0.1.0`. The workflow builds a universal (Apple silicon and Intel) Release app on `macos-26`, signs it ad hoc, checks the signature, zips it with `ditto`, and attaches the zip and its SHA-256 file to a GitHub release. A tag with a dash (`v0.2.0-rc1`) is marked as a pre-release.
- **Try the build without publishing:** run the workflow by hand from the Actions tab. It builds the same zip and keeps it as a workflow artifact for 14 days. It creates no release.
- **Signing:** ad hoc only. Users must right-click the app and choose Open the first time. Developer ID signing and notarization wait until Berat joins the Apple Developer Program; they would replace the `CODE_SIGN_IDENTITY=-` setting and add a notarize step.
- A tag cannot be re-used. If a release is wrong, delete the release and the tag, then tag again with a new version.
