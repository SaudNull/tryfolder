# Release preparation — 0.1.0

This prepares the normal 0.1.0 release. Apple Silicon was tested on macOS 26.4.1; macOS 14 is the deployment target and remains untested. Guarded Apply/Undo are enabled by `ReleaseCapabilities.applyAndUndo`. The core uses full metadata-preserving copies; clone optimization is deferred. Same-volume automated verification used the APFS SSD `/Volumes/Main`; do not infer general external-volume or cross-volume support. `.DS_Store` is a reported exclusion alongside the documented dependency/Git/build exclusions.

Integrated evidence: **47 XCTest methods passed, 0 failures, 17.006 seconds** (26 acceptance, 8 security, 13 core) (`Artifacts/test-results.txt`), including one method containing **50 competing-export contests**. Separately, **36 true subprocess `_exit(86)` interruption/recovery scenarios passed**, including recovery/idempotence checks (`Artifacts/process-crash-results.json`). The final focused security review of MutationLock ownership reported clear. These results do not establish power-loss durability or universal protection from concurrent writers. See [QA-MATRIX.md](QA-MATRIX.md), [SECURITY-REVIEW.md](SECURITY-REVIEW.md), and the integration-owned [VERIFICATION.md](VERIFICATION.md).

## Native evidence and remaining release work

The integrator verified Finder/TextEdit → review of three real changes; Keep → selected text Apply → Undo restoring seven original hashes → Discard preserving the kept output. The separate Tuesday-baseline / Wednesday-original / Thursday-draft scenario correctly showed a conflict and exported the draft separately. PNG/PDF previews rendered. A later selected text Apply/Undo preserved other files and the conflict; the last-read preview refreshed correctly. `.DS_Store` exclusion and UF_TRACKED support were corrected and tested. The final fixed build survived PDF/text preview switching, New Draft cancellation and creation, and fresh edit/review/discard and Keep workflows. Quitting with a PDF visible and relaunching normally with no arguments restored the SSD store and PDF previews in both panes. Final fixed-build captures are `Docs/Images/start.png`, `review.png`, `conflict.png`, and `pdf-review.png`. Older development captures remain outside the public screenshot set.

- Record the exact commit, `sw_vers`, `uname -m`, `swift --version`, and `xcodebuild -version`.
- Preserve the passing automated evidence above with the exact final code revision. Rerun only if subsequent source changes warrant it; record remaining gaps in [QA-MATRIX.md](QA-MATRIX.md). Process exits and fault throws do not establish power-loss durability.
- Final store persistence is verified by the normal no-arguments relaunch described above. Preserve the native flow evidence and record only accessibility/appearance checks actually performed.
- Final single-run measurement: 1,003 files, 138,313,745 bytes, three changes; prepare **2.481 seconds**, review **1.875 seconds** ([public measurement data](../Artifacts/performance-results.json)). Six short release-app idle samples while displaying restored sealed review recorded **0.0% CPU** and **74,432–74,576 KiB RSS** ([public idle samples](../Artifacts/performance-results.json)). Tested on the MacBook Air M4, macOS 26.4.1. These are observed single-run/short-sample results, not general performance guarantees.
- All four Arabic and English [native-footage demos](DEMO.md) are complete: main stories 34.166 seconds and conflict stories 25.066 seconds per language; 1920×1080, nominal 60 fps, silent H.264. Full decode and visual QA passed; each is labeled edited. The original continuous 10–20-second brief was not achieved; this disclosed presentation change does not block the source-first 0.1.0 release.
- Final fixed build and native relaunch were verified by the integrator. The local ZIP is `dist/TryFolder-0.1.0-macos-arm64-local.zip`; its SHA256 is `cc41c57ba8273fa605fc7de837dd5eaa38ad1751d6dd6c162faae07fe901db1a`. Packaging also produces `dist/TryFolder.app` and `dist/SHA256SUMS.txt`.

Build/package scripts keep outputs local and ad-hoc sign with `codesign --sign -`. Developer ID signing and notarization are incomplete: the integration host identity check reported **0 valid identities**. Do not describe ad-hoc signing as a verified publisher identity. The integrated test results above are integration evidence, not an independent rerun by the documentation engineer. Final package, performance, and CI records are owned by the integrator and recorded in [VERIFICATION.md](VERIFICATION.md).

## CI contract

`.github/workflows/ci.yml` tests and creates a local archive on `macos-15`, then verifies signature integrity, arm64 presence, and checksum. It does not upload build artifacts, publish releases, import credentials, or notarize. The owner has authorized GitHub publication. The [first hosted CI run](https://github.com/SaudNull/tryfolder/actions/runs/39306253203) is queued; no passing result is claimed here.

GitHub's [current standard runner table](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) lists `macos-15` as arm64 and `macos-15-intel` as Intel (checked 2026-10-19 through official docs and Context7). The workflow also fails if `uname -m` is not `arm64`. Runner images can change; record the actual toolchain from each run. This CI does not verify Intel or every supported macOS version.

## Manual Developer ID / notarization next actions

These are instructions for a future authorized release operator; **they have not been executed**. GitHub publication is already authorized. Certificate/account setup, credential storage, and notarization upload remain separate future actions requiring the owner's authorization. Do not purchase membership or change accounts as part of local packaging.

1. Obtain an existing valid **Developer ID Application** identity and confirm it using `security find-identity -v -p codesigning`. Confirm the intended owner controls `app.tryfolder.mac`; change the bundle identifier before signing if needed. Review the built bundle for nested code and entitlements. The current bundle has one executable and no intentional nested framework/helper code; reassess if dependencies change.
2. Run the tests and build a release locally with `./script/build.sh release`. Copy the app to a separate signing directory so rebuilding cannot replace the candidate. From the checkout root:

   ```sh
   mkdir -p Artifacts/ReleaseSigning
   test ! -e Artifacts/ReleaseSigning/TryFolder.app
   /usr/bin/ditto dist/TryFolder.app Artifacts/ReleaseSigning/TryFolder.app
   ```

3. Replace the example identity below with the actual valid identity. Sign the app with hardened runtime and secure timestamp. Do not use `--deep` as a substitute for signing nested code in the correct order. No entitlement exceptions are presently required by this single-executable design; inspect and test rather than adding permissive defaults.

   ```sh
   TRYFOLDER_SIGNING_IDENTITY='Developer ID Application: OWNER (TEAMID)'
   /usr/bin/codesign --force --options runtime --timestamp \
     --sign "$TRYFOLDER_SIGNING_IDENTITY" Artifacts/ReleaseSigning/TryFolder.app
   /usr/bin/codesign --verify --strict --verbose=2 Artifacts/ReleaseSigning/TryFolder.app
   /usr/bin/codesign -d --verbose=4 Artifacts/ReleaseSigning/TryFolder.app
   /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
     Artifacts/ReleaseSigning/TryFolder.app Artifacts/ReleaseSigning/TryFolder-submit.zip
   ```

4. With authorization, store notarization credentials interactively in Keychain (keep secrets out of commands, logs, and the repository), then submit the archive. Local `notarytool` help confirms the interactive credential prompt and `submit --keychain-profile --wait` syntax. This step contacts Apple and uploads the archive.

   ```sh
   xcrun notarytool store-credentials TryFolder-notary
   xcrun notarytool submit Artifacts/ReleaseSigning/TryFolder-submit.zip \
     --keychain-profile TryFolder-notary --wait
   ```

5. Proceed only after status **Accepted**. For an invalid submission, retrieve the real submission log with `xcrun notarytool log SUBMISSION_ID --keychain-profile TryFolder-notary Artifacts/ReleaseSigning/notary-log.json` and fix the reported issue. Then staple and assess the app:

   ```sh
   xcrun stapler staple Artifacts/ReleaseSigning/TryFolder.app
   xcrun stapler validate Artifacts/ReleaseSigning/TryFolder.app
   /usr/sbin/spctl --assess --type execute --verbose=4 Artifacts/ReleaseSigning/TryFolder.app
   ```

6. Repackage **after stapling**, giving the distributable a distinct name, and compute its checksum. Re-running `script/package.sh` would rebuild/re-ad-hoc-sign a different app and must not replace this candidate.

   ```sh
   /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
     Artifacts/ReleaseSigning/TryFolder.app \
     Artifacts/ReleaseSigning/TryFolder-0.1.0-macos-arm64.zip
   /usr/bin/shasum -a 256 Artifacts/ReleaseSigning/TryFolder-0.1.0-macos-arm64.zip
   ```

Verify a clean extraction and normal Finder/Gatekeeper launch of the final archive on a separate test Mac/user, with the real distribution/quarantine path when available. Record results and notarization receipt. Do not remove quarantine, disable platform security globally, or infer notarization from `codesign --verify` alone. Prepare a Homebrew cask only after an authorized published asset URL and its real SHA256 exist.

Apple references: [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), and [resolving notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues).

## Publication boundary

The owner explicitly authorized continuing and publishing to GitHub. The public repository [SaudNull/tryfolder](https://github.com/SaudNull/tryfolder) is verified, with default branch `main` and initial source commit `bcd49da17e46427217a58cca77e125c56c2f1100`. Normal `0.1.0` release publication remains pending. The integrator owns repository creation, final build/assets, publication, and the actual CI/result record; this documentation edit does not claim those actions occurred. Publish 0.1.0 as a normal release and disclose ad-hoc signing. A normal GitHub release does not establish Developer ID signing or notarization. Developer ID signing/notarization remains incomplete. No launch posts or community outreach are part of this publication scope.
