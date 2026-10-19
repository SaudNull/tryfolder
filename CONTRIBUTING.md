# Contributing

TryFolder is a SwiftUI/AppKit macOS app with a testable Swift core. Use an Apple Silicon Mac with macOS 14+ and Swift 6+. Read [AGENTS.md](AGENTS.md) and [the filesystem contract](Docs/FILESYSTEM_CONTRACT.md) first.

Run `./script/test.sh`, then `./script/build.sh debug`. Use synthetic, disposable fixtures only; tests retain evidence under `Artifacts/TestRuns`. Use `./script/build_and_run.sh --demo` for a project-local session store on the fixture's volume. Never test mutations on real user documents. Report the actual toolchain, test command/results, and manual checks with your change.

Keep changes focused. For filesystem changes, include a behavior test showing that unrelated files and newer external edits survive the failure case. Preserve all versions on ambiguity. Changes to Apply/Undo must preserve the integrated release gates. Do not add broad cleanup, silently omit unsupported input, or describe a draft as a security sandbox. No publishing or account changes are part of a normal contribution.

Choose a bounded task and discuss the acceptance condition before expanding it:

1. Add a bounded preview for one currently unsupported regular-file type, with oversized/malformed input handling.
2. Verify one metadata category on disposable files and document exactly what survives capture/export.
3. Extend the existing process-exit recovery harness for a newly introduced journal boundary, preserving pre/post/review bytes as evidence.
4. Audit one keyboard/VoiceOver journey from selection through export in Light and Dark appearance.
5. Add an Arabic/mixed-direction filename fixture and verify display, review, and export without renaming it.
6. Measure preparation/review time and memory for one disclosed fixture on a named Mac; record method and limits.

Defer cloud/network volumes, directory metadata versioning, automatic merges, rename inference, Intel distribution, and new automation runners until their capabilities have a separate tested contract.
