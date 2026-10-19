# Technical evidence consulted

19 October 2026. Research was bounded to the implementation contract and one prior-art pass.

- Apple Foundation / NSFileCoordinator documentation (via Context7): coordinates registered file presenters; it is not a lock against every process. https://developer.apple.com/documentation/foundation/nsfilecoordinator
- Installed macOS SDK: `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/sys/clonefile.h`, `copyfile.h`, `stdio.h`, and `usr/share/man/man2/clonefile.2` / `man3/copyfile.3` are the authority for available flags. Per-file copying avoids unsupported assumptions about cloning directory trees.
- Apple APFS APIs background: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/ToolsandAPIs/ToolsandAPIs.html
- Current Apple clonefile manual: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/clonefile.2
- SwiftPM CLI documentation (via Context7) checked for build cache/scratch paths and product discovery: https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/SwiftBuild.md

Prior art includes BranchFS filesystem branching (https://github.com/multikernel/branchfs) and DeltaSnap APFS snapshot management (https://scaleninja.com/deltasnap/). TryFolder focuses on an ordinary copied folder edited using existing Mac apps and reviewed through a native interface. No uniqueness or universal-undo claim is made. Generated concept images are design references, never evidence of this implementation.
