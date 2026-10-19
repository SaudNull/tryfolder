# TryFolder security and loss-prevention review

Reviewed 19 October 2026 on the actual macOS host and mounted project SSD. This was an independent review of `SafeFilesystem.swift`, `DurableStore.swift`, `SessionEngine.swift`, their public models, and the native preview/open path. It was bounded to one full implementation review, targeted regression verification, and one integrator-authorized follow-up on the concrete pending-recovery reservation defect. No remote service, external account, or real user document was used.

Daybreak was not callable in this host. The reviewer fallback was **`gpt-6.1-sol`, XHigh reasoning**, as confirmed by the integrator. This is not equivalent to specialist Daybreak coverage. No claim of cryptographic integrity, hostile-process confinement, or universal filesystem safety is made.

## Reproduced findings

The regression cases are in `Tests/TryFolderCoreTests/SecurityRegressionTests.swift`. Synthetic evidence is retained under `Artifacts/TestRuns/security-*`.

| Finding | Initial evidence | Required resolution | Status |
| --- | --- | --- | --- |
| P1: stored changeset could relabel a genuine source conflict | Create a conflict review; change only `review.json`'s selected entry to `baseline = current`, `kind = edited`. Apply succeeded and replaced a newer original with the sealed draft. Genuine baseline and sealed manifest were unchanged. | Compare saved baseline observations against the independently validated baseline; validate applicable kind and current/baseline relationship before any mutation. | Fixed; independent regression passes. |
| P1: recovery installed corrupted displaced bytes before rejecting them | Interrupt at `apply.afterMutation`, replace `transactions/<id>/staged/proposal.txt` with synthetic corrupt bytes, then recover. Recovery threw only after changing the source to those corrupt bytes. | Verify displaced content and identity before any recovery rename and again at its mutation boundary. Preserve ambiguous material for manual review. | Fixed; independent regression passes. |
| P1: replaced inner ancestor accepted until after mutation | At `apply.beforeMutation`, move `Source/Folder` aside and create a different ordinary `Source/Folder/file.txt`. Apply threw after replacing that new unrelated entry with reviewed content. The selected root itself never changed. | Pin inner directory identities, revalidate after callbacks, and validate the directory descriptors used for rename; carry required pins in journal/receipt operations. | Fixed; independent regression passes. |
| P1: macOS firmlink alias bypassed source/store containment check | `/Volumes` and `/System/Volumes/Data/Volumes` shared device/inode on this host. With an aliased custom store inside the canonical selected source, create wrote a session subtree into the source before later failing a rescan. | Check device/inode ancestry for existing source/store and export parents before creating content; retain lexical checks as an additional guard. | Fixed; independent regression passes on this host without skipping. |
| P2: case aliases bypassed protected-root/exclusion policy | Initial code compared protected roots and excluded names case-sensitively despite case-insensitive APFS. `.GIT/config` was eligible for capture; an alternate case of the user's Library path bypassed the path policy. Credential roots also needed explicit rejection. | Apply normalized policy comparisons and reject supported account/credential-root patterns. | Fixed; protected-root and synthetic `.GIT` regressions passed independently. |
| P2: contradictory journal completion could be trusted | The root journal's status was not compared against its transaction journal, although the latter is written first. A modified root status could claim completion ahead of an active transaction. | Reject impossible pointer-ahead completion while allowing conservative handling of a transaction that is durably ahead of its root pointer after a crash. | Fixed; independent regression passes. |
| P1: active recovery lacked durable cross-store ownership | Another store could capture a partially applied source as a baseline and apply over it after the first process released its operation lock, making the first recovery ambiguous. | Persist shared source ownership before any attempted mutation, match lexical and filesystem-identity ancestry, and release only after durable terminal state. | Fixed; three independent reservation cases pass, including same/different stores, unavailable owner store and durability gaps. |
| P2: untouched pre-reservation journal could strand recovery | Interrupt after journal persistence but before reservation; another store validly applies; recovery of the wholly staged transaction failed against the later bytes. | Cancel a wholly staged, never-attempted transaction without reading or changing source content; preserve any later source edit. | Reproduced, fixed; independent regression passes. |

The P1 regressions demonstrably changed the source entry before the rejected operation completed, or allowed Apply over a genuine conflict. Retained copies prevented permanent byte loss in these fixtures; that does not make the initial behavior acceptable.

## Reviewed controls and boundaries

* Absolute and relative traversal opens each component with `O_NOFOLLOW`; user paths use descriptor-relative `openat` and guarded rename. Relative paths reject absolute names, `.`/`..`, empty components and NUL. Persisted session and snapshot URLs are replaced by UUID-derived locations under validated session storage.
* Regular file reads reject symlinks, hard links, special files, nested devices, unsupported flags, ACL entries and relevant cloud/compression metadata. Hashing streams content; capture checks source stability and copied content/metadata.
* Mutation methods share one fixed per-user interprocess `flock`, including custom stores, covering validation, durable journal writes, mutation and verification. Durable reservations extend source ownership beyond process lifetime until a terminal journal is durable. A same-user process deliberately replacing the lock inode remains outside this cooperative locking boundary.
* Apply acts on explicitly selected file paths. No recursive source-directory deletion is present. Excluded and unselected descendants survive parent-level draft deletion; empty source directories are retained.
* Reviewed bytes are copied into a separately validated snapshot. Keep constructs a private verified staging directory and publishes with `RENAME_EXCL`; it cannot merge into an existing output. Discard archives logically and does not remove user-owned exports.
* Apply records recovery/staged content before mutation; replacements exchange entries and removals retain actual displaced files. Undo checks expected current content and identity against its receipt. Ambiguous state keeps baseline, sealed and recovery versions.

Existing acceptance tests cover traversal selections, static symbolic/hard links, source replacement, source conflicts, sealed-copy tampering, exclusion preservation, no-overwrite export, independent-store locking, Undo freshness and injected apply/undo/recovery interruption boundaries. Root integration owns native UI smoke and a real process-termination probe; this review did not independently repeat those experiments.

## Preview limitation

Text and image previews read bounded bytes through a no-follow descriptor. Quick Look and external applications receive a checked URL and may reopen it later; the descriptor check does not confine that later reopen. The current-original pane also represents live content, while review metadata is an earlier observation. These are practical display/open boundaries, not guarantees against a hostile same-user writer. Do not describe the preview or draft as a security sandbox or a tamper-proof approval display.

## Verification and release conclusion

Initial independent checkpoint: all 7 security regressions passed. The authorized reservation follow-up added one specific regression after reproducing its failure. Final independent command, using the shared SSD coordination root:

```sh
TRYFOLDER_COORDINATION_ROOT=/Volumes/Main/Personal/Projects/tryfolder/Artifacts/Coordination swift test --scratch-path .build --filter 'SecurityRegressionTests|EngineUnitTests.testPendingOwnerBlocksOverlappingSessionsAcrossSameAndDifferentStoresUntilRecovered|EngineUnitTests.testReservationDurabilityGapsRecoverWithoutReleasingUncommittedOwner|EngineUnitTests.testUnavailableUnresolvedStoreDoesNotPruneItsReservation'
```

All **11 targeted tests passed, zero failures, zero skips**, in **2.459 seconds**, finishing at host timestamp **2026-10-19 01:18:59**. This includes 8 security cases and 3 reservation cases. The filesystem owner separately reported a wider 42-case pass before the final narrow cancellation/Finder adjustments; the integrator owns the final complete-suite count, native smoke, packaging and real process-termination verification.

**Security C conclusion:** the concrete pending-recovery ownership blocker is resolved in the reviewed implementation and targeted behaviors. No unresolved release blocker remains from this bounded review. Public Apply/Undo enablement still depends on the integrator's complete mutation, real interruption, native and packaging gates. These tests do not establish safety under arbitrary concurrent writers, disk failure, every mount configuration or coordinated modification of all stored records.

### Persistent overlap follow-up

The original global lock alone did **not** guard a source after its owning process exited or released the operation lock while leaving an active recovery journal. `requireNoPending` checked the selected session only. A second session, including one in another custom store, could capture the first session's partial poststate as a new baseline, apply a new edit to that path, and cause the first session's recovery to stop as ambiguous. This was an integrator-requested, concrete C blocker.

The follow-up introduces a shared, identity-checked registry under `~/Library/Application Support/TryFolder/Coordination`. Its private directory, no-follow lock/JSON access, durable writes, source ancestor identities and owner tuple cover independent stores. Apply and Undo check existing reservations before staging a transaction; recovery exempts its exact owner only. Active mutations reserve after a durable journal and before the attempted/mutation boundary; terminal journal durability precedes release. Missing owner storage never causes automatic pruning. The reviewer checked these paths directly.

One boundary was reproduced and fixed during that follow-up: crash/fault after journal persistence but before reservation lets another store legitimately apply while the first transaction is wholly staged and untouched. Recovery previously conflicted with the later edit. `testJournalBeforeReservationCannotStrandRecoveryAfterAnotherStoresApply` now passes: recovery cancels the untouched transaction, durably marks it recovered and releases only its exact owner without opening, hashing or changing the source. Attempted operations continue to use guarded rollback. The later app-owned edit remains intact.

Test processes use the **same** explicit `TRYFOLDER_COORDINATION_ROOT=/Volumes/Main/Personal/Projects/tryfolder/Artifacts/Coordination`; changing this root creates a separate coordination domain and is not supported for cooperating concurrent instances. No registry was silently expired or pruned during verification.

### Focused initializer ownership follow-up

The integrator identified and requested a narrow review of a double-close in `MutationLock`'s throwing initializer. The corrected initializer keeps the coordination directory and lock descriptor local through every throwing check. A local failure defer unlocks only if acquired and closes the descriptor once. Only after all checks succeed are both stored properties assigned and ownership marked transferred; no throwing operation follows that transfer. Successful instances leave descriptor cleanup solely to `deinit`, while the retained `SafeDirectory` owns its separate directory descriptor. This establishes one cleanup owner on each reviewed success/failure path. The focused source review found no remaining duplicate-close path. No tests were run during this follow-up because the integrator's serial gates were executing.
