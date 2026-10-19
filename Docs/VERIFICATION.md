# Local release verification

2026-10-19, Asia/Riyadh. Synthetic files only. TryFolder 0.1.0, Apple Silicon. The package is ad-hoc signed and is not notarized. Public repository/release and CI status are recorded separately below.

## Environment

MacBook Air M4 (Mac16,12), 16 GB RAM, macOS 26.4.1, Swift 6.3.3 / Xcode 26.6. Project, synthetic source and explicit session store on the mounted APFS `/Volumes/Main` SSD. macOS 14 is the deployment target; it was not run on macOS 14 or Intel. Build/cache outputs are project-local.

## Automated evidence

The corrected integrated run passed 47 XCTest methods (26 independent acceptance, 8 security, 13 core), zero failures, 17.006 seconds. `Artifacts/test-results.txt` holds the output. One core method runs 50 competing-export contests and verifies exactly one intact output each time. A throwing-initializer descriptor double-close discovered during integration was corrected and independently reviewed.

`python3 script/check_crash_recovery.py` passed 36 true subprocess interruption scenarios. Each helper exits abruptly with `_exit(86)` at one journal, reservation, mutation, verification or terminal boundary; a fresh process then recovers twice. Selected add/edit/remove contents match the expected pre- or post-transaction state. Evidence: `Artifacts/process-crash-results.json`. These are process-exit checks, not physical power-loss tests.

The full matrix is in [QA-MATRIX.md](QA-MATRIX.md); focused findings and remediation are in [SECURITY-REVIEW.md](SECURITY-REVIEW.md). Injected ENOSPC/EACCES/EIO establish error-path behavior, not actual disk exhaustion or device-detach behavior. A case-sensitive volume and normalization-collision fixture remain untested.

## Native verification

The real SwiftUI/AppKit bundle completed the full native workflow on synthetic APFS fixtures. Finder opened the exact draft. TextEdit edited proposal.txt; Finder duplicated it and moved a draft outline to Trash. Review reported one addition, one edit and one removal. Keep exported the sealed revision. Selective Apply changed only the selected proposal; Undo restored all seven original hashes. Discard retained the archived draft, preserved originals and left the kept export intact.

In the conflict flow, TextEdit changed the draft to Thursday and independently changed the source to Wednesday. The review showed the Tuesday baseline, Wednesday current original and Thursday draft. Conflict Apply was disabled; Keep exported Thursday while Wednesday remained in the source. Image and PDF previews rendered. A separately selected added text file applied, its current-original preview refreshed immediately, and Undo removed it while preserving unselected image/PDF files.

Ordinary no-arguments relaunch restored the explicit SSD session store and unfinished Campus visit review. This was repeated successfully after the final 0.1.0 version build. The native Finder `.DS_Store` exclusion and TextEdit `UF_TRACKED` compatibility regressions are covered by the completed tests.

The final 0.1.0 filming repeated Create → TextEdit/Finder edit/add/remove → Review → Discard. All three filmed source hashes remained unchanged. A second real take repeated external-source conflict detection and independent Keep; disk contents confirmed Wednesday in the source and Thursday in the kept output. Four edited presentations are exported: Arabic/English main videos (34.166 seconds each) and conflict videos (25.066 seconds each), 1920×1080, nominal 60 fps, H.264, silent. The production worker decoded all four files completely without errors and inspected final frames/transitions for Arabic shaping, readable comparisons and unrelated desktop content. Root also inspected exported main/conflict frames. Public-safe hashes and source provenance are in `Artifacts/video-evidence.json`. These are edited window-only recordings, not the requested continuous 10–20-second full workflow.

## Preview lifecycle correction

Filming exposed an AppKit Quick Look teardown abort when switching a PDF review to New Draft. The crash reports identified `QLPreviewView.deactivate` after SwiftUI dismantling. The bridge now uses an ordinary NSView host with explicit one-time child close. The corrected release compiled and packaged successfully. With removable-volume access granted, the same process (PID 86477) survived two PDF → New Draft transitions, including cancel/reopen and creating a new draft, plus PDF/text/PDF selection and the newly filmed workflow. Quitting while the PDF was visible and relaunching the final bundle normally with no arguments restored the SSD store and both PDF previews. No new TryFolder diagnostic report appeared after the corrected process launch. The reproduced teardown blocker is resolved within this tested sequence.

## Measurements

One isolated release-core run on 1,003 files totaling 138,313,745 bytes (1,000 4 KiB documents, one 128 MiB file, two small text files), with three draft changes: prepare **2.481 seconds**, seal/review **1.875 seconds**, peak RSS **18,513,920 bytes**, measured by `/usr/bin/time -l`. No concurrent build ran during this measurement. Core RSS excludes the GUI. Public measurements: [performance-results.json](../Artifacts/performance-results.json). Raw local evidence is retained under ignored `Artifacts/Performance`.

Six one-second idle samples of the release app showing a restored sealed review measured 0.0% CPU each, CPU time 1.39 → 1.40 seconds, RSS 74,432–74,576 KiB. This short observation is not a long-duration power/idle guarantee. Raw local evidence: `Artifacts/Performance/idle-release.json`.

## Packaging and publication

The final 0.1.0 arm64 app and ZIP were rebuilt. Plist validation, strict ad-hoc signature verification, extraction and executable-byte comparison passed. Archive SHA-256: `cc41c57ba8273fa605fc7de837dd5eaa38ad1751d6dd6c162faae07fe901db1a`. Evidence: `Artifacts/package-results.txt`, `Artifacts/native-package-results.json`.

No Developer ID identity is installed; signing with Developer ID and notarization remain incomplete. macOS 14, Intel, case-sensitive/normalization-collision volumes, physical power loss/disk exhaustion/device detach and a complete VoiceOver/Reduce Motion/appearance audit were not validated. Native labels/keyboard actions exist; no full accessibility audit is claimed.

The public repository is [SaudNull/tryfolder](https://github.com/SaudNull/tryfolder), verified PUBLIC with default branch main. Hosted CI for source commit `bcd49da17e46427217a58cca77e125c56c2f1100` is queued at [run 39306253203](https://github.com/SaudNull/tryfolder/actions/runs/39306253203); a queued run is not a passing result. [Release v0.1.0](https://github.com/SaudNull/tryfolder/releases/tag/v0.1.0) is published (not draft or prerelease), targeting `b210324153485173d5b4abba3ab19011633110fe`. All six assets are uploaded, and GitHub-reported SHA-256 digests/byte lengths match the local ZIP, checksum file and four reviewed MP4s. Source, tests, resources, build scripts and workflow are unchanged from the CI source commit; intervening commits contain documentation/evidence only. Public receipt: [publication-results.json](../Artifacts/publication-results.json). See [DEMO.md](DEMO.md) for final assets/status.
