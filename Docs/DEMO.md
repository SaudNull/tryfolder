# Native-app demos — 0.1.0

**All four videos are complete and verified.** Each uses clean window-only footage of the actual native app and is an **edited presentation**. All four are published with the normal [0.1.0 release](https://github.com/SaudNull/tryfolder/releases/tag/v0.1.0).

| Asset | Language | Duration |
| --- | --- | --- |
| [TryFolder-Main-AR.mp4](https://github.com/SaudNull/tryfolder/releases/download/v0.1.0/TryFolder-Main-AR.mp4) | Arabic | 34.166 s |
| [TryFolder-Main-EN.mp4](https://github.com/SaudNull/tryfolder/releases/download/v0.1.0/TryFolder-Main-EN.mp4) | English | 34.166 s |
| [TryFolder-Conflict-AR.mp4](https://github.com/SaudNull/tryfolder/releases/download/v0.1.0/TryFolder-Conflict-AR.mp4) | Arabic | 25.066 s |
| [TryFolder-Conflict-EN.mp4](https://github.com/SaudNull/tryfolder/releases/download/v0.1.0/TryFolder-Conflict-EN.mp4) | English | 25.066 s |

All four are 1920×1080, nominal 60 fps, silent H.264. Full ffmpeg decode and visual checks passed. Public-safe evidence is recorded in [video-evidence.json](../Artifacts/video-evidence.json); local exports are in `Deliverables`.

The original brief called for continuous 10–20-second demonstrations. That scope was not achieved: the current production uses longer edited stories. This deviation is disclosed and does not block the source-first normal 0.1.0 release. Do not describe these videos as continuous proof of the entire create → edit → review → keep/discard workflow.

## What the footage demonstrates

The main story introduces a separate draft and the real review interface. The conflict story shows the starting version, current original, and sealed draft with the original protected. Captions in Arabic and English must describe the actual visible actions. Arabic captions do not imply a localized app interface; full Arabic localization remains deferred. Use synthetic study/campus files only.

Final fixed-build screenshots: [start](Images/start.png), [review](Images/review.png), [conflict](Images/conflict.png), and [PDF preview](Images/pdf-review.png). These are actual app captures. Earlier development captures remain separate; generated concept images are not implementation evidence.

## Native verification behind the presentation

The integrator independently exercised Finder/TextEdit draft editing, three-change review, Keep, selected Apply, Undo restoring seven original hashes, and Discard preserving the exported folder. A separate Tuesday-baseline / Wednesday-original / Thursday-draft scenario showed the conflict and kept the draft separately. PNG/PDF previews and original-preview refresh passed.

The final fixed build survived PDF → New Draft → Cancel, PDF/text/PDF switching, and a new draft creation in the same process. Fresh edit/review/discard and Keep workflows passed. After quitting with a PDF visible, a normal no-arguments relaunch restored the SSD session store and PDF previews in both panes. These observed checks are separate from the edited videos. See [VERIFICATION.md](VERIFICATION.md) for the evidence and its limits.

## Export acceptance

Export QA is complete: durations, dimensions, languages and encoding were checked; full decode and visual checks passed. The four outputs use the edited-presentation label. Preserve original footage inside ignored `Artifacts`. Publish only reviewed outputs. The [public source repository](https://github.com/SaudNull/tryfolder) is verified. The normal 0.1.0 release and all six assets are verified public; GitHub asset SHA256 values match the local files.
