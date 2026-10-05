# Local integration of the audio and battery snapshot

The user selected archived snapshot `a17adfebf84b28577c77552517a14725c124be16` (version 1.3.8, build 28), based on audio branch commit `683ed8db578d4811edd0636c9e480bab1687ebbe`, for integration into local main. Existing subprocess timeout changes and documentation edits were preserved in the integration candidate. The original worktree changes are retained in a named Git stash during integration.

## Verification

The integration candidate passed 1046 XCTest tests (6 skipped, 0 failures) and 325 Swift Testing tests. Its arm64 and x86_64 release app passed deep/strict code-signature validation and LC_BUILD_VERSION checks (minos 15.0, sdk 26.0).

These checks ran in a temporary source copy using the local Sparkle 2.9.6 XCFramework, matching Package.resolved. The temporary manifest used a local binary target and the temporary bundle script read that framework from Vendor. The repository manifest and build script retain their upstream dependency configuration. Local toolchain: Swift 6.4 / macOS SDK 27. This does not prove CI toolchain compatibility.

Non-publishing CI is pending. The fork ZhangEx18/status-trio returned no registered Actions workflows, and enabling release.yml returned HTTP 404 despite its source file being present. The upstream repository is read-only to the signed-in account. On 2026-10-05, the user explicitly authorized local integration after local verification with CI recorded as pending. No public release or appcast publication was performed.

## Independent review and remaining limits

Architect review confirmed main is an ancestor of the selected snapshot. It found an existing unsynchronized gain scalar shared by MainActor setters and the Core Audio callback in CoreAudioProcessTapManager. This predates integration; it is retained for this restoration and needs an atomic scalar fix before public release. Screen capture permission checks used for per-app audio also need real-device validation against system audio permission behavior.

Automated tests and signing checks do not establish real-device audio routing, permission prompts, or equivalence of the displayed UI. The local app is Ad-hoc signed and not notarized.
