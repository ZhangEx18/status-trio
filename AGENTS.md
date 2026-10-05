# Status Trio Agent Rules

## Highest Priority: Match the CI Toolchain

The release workflow is the acceptance environment:

- Runner: `macos-26`
- Xcode: `26.6`
- Swift: `6.3.3`

A newer local toolchain is useful, but it is not proof that CI will compile. Swift code must remain buildable with the CI toolchain.

The app must be built with the macOS 26 SDK or newer. macOS reads the `LC_BUILD_VERSION` `sdk` field to decide whether an app adopts the current design language, so building with an older SDK silently ships the pre-Tahoe popover appearance (issue #40). `scripts/build-app.sh` fails when the SDK is older than 26, and `scripts/verify-platform-version.sh` asserts the result; do not remove either.

Before committing Swift changes:

```bash
swift test
swift build -c release
```

If a change touches actor isolation, `@MainActor`, `deinit`, SwiftUI bindings, generics, or `Bundle.module` resources, also run a non-publishing release workflow before merging or publishing:

```bash
gh workflow run release.yml \
  --repo lingyired/status-trio \
  --ref <branch> \
  -f version=<next-version> \
  -f build=<next-build> \
  -f publish=false

gh run watch <run-id> --repo lingyired/status-trio --exit-status
```

Do not create a release if that preflight has not passed.

Every failed GitHub Actions run must be added to
[Swift toolchain CI compatibility](docs/swift-ci-compatibility.md), including the
run ID, failed stage, root cause, fix, and verification result.

## Swift Toolchain Compatibility Rules

- Do not use `isolated deinit` or enable the `IsolatedDeinit` experimental feature. Use `deinit` with explicit cleanup; use `nonisolated(unsafe)` only for teardown-owned storage and explain why it is safe.
- Do not pass actor-isolated methods directly as function values. Use an explicit closure instead.
- Do not write `weak let`; weak reference bindings must be `var` (when the compiler asks for `weak let` to silence a never-mutated warning, use the test target's `DeinitProbe` instead and see [Swift toolchain CI compatibility](docs/swift-ci-compatibility.md)).
- Do not assume SwiftPM `Bundle.module` resource names or directory casing match local builds. For localized resources, try the canonical and lowercase `lproj` names and load with `Bundle(path:)`.
- If the Swift compiler crashes with `IRGenRequest`, `SmallVector unable to grow`, or a signal 6, reduce the code pattern that causes the crash. Do not treat it as a flaky failure and do not hide it with experimental compiler flags.

## External macOS commands and privacy boundaries

- Synchronous reads from system tools (`/usr/sbin/system_profiler`, `/usr/sbin/networksetup`, and `/usr/bin/pmset`) must use `BoundedProcessRun.run(...)` with a documented deadline. Do not add an unbounded `readDataToEndOfFile()` followed by `waitUntilExit()` on a monitor's serial queue; a wedged tool would pin later status updates for the rest of the session.
- A launch failure, non-zero exit, timeout, or incomplete output must degrade to the existing empty or `nil` result. Do not parse partial output from a killed process as a valid status report. Keep timeout and escalation behavior covered in `BoundedProcessRunTests`.
- `pmset -g accps -xml` is an optional, undocumented accessory-battery fallback. Keep the documented `system_profiler` report as the primary source, and do not replace this fallback with private symbols, new entitlements, or a privileged helper.
- Status Trio does not read or store Wi-Fi passwords. Network switching remains delegated to System Settings; do not add Keychain password reads, password caches, SMC charge-control writes, or other privileged control paths.
- The optional audio-input section reads device inventory, the default device, in-use state, gain, and mute status. It may switch devices or write supported gain/mute controls, but it must not capture, record, or persist microphone audio; keep the input monitor stopped when that section is disabled.
- App Audio is a separate opt-in feature: per-app controls use a private Core Audio process tap and system audio permission. Audio buffers remain local and must not be uploaded or persisted. Battery telemetry and device profiles are stored locally; document their retention and the best-effort read-only PowerUI charge-limit lookup accurately.

## Change Flow

- Small, low-risk changes — especially your own follow-up tweaks — go straight to `main`: commit directly, or use a short-lived branch and fast-forward it into `main`. No pull request is required.
- Use a pull request when a change is large, touches several subsystems, or when a review/discussion record is worth keeping.
- Whichever route is taken, the verification rules above still apply: `swift test` and `swift build -c release`, plus a non-publishing release workflow run when the change touches actor isolation, `@MainActor`, `deinit`, SwiftUI bindings, generics, or `Bundle.module` resources.
- The release workflow only runs on tags and manual dispatches, so a pull request does not add CI coverage on its own.

## Local build and test entry points

- `bash scripts/test.sh` is the normal local test entry point because it runs `scripts/check-forbidden-patterns.sh` before `swift test`. A focused test may be passed as its first argument.
- `bash scripts/build-app.sh release [no-open]` creates the signed `dist/StatusTrio.app` bundle and enforces the SDK and `LC_BUILD_VERSION` checks. Use `bash scripts/build-worktree.sh release` for a side-by-side worktree build; it derives a development bundle identifier and display name so it does not replace the production app.
- Keep subprocess, AppKit, and SwiftUI tests deterministic. Prefer bounded polling or an explicit test clock over fixed sleeps when a state change is asynchronous; record any CI-only failure in `docs/swift-ci-compatibility.md` with its run ID and remediation.

## Menu Bar and Dock Icon Parity

- Every change to a menu bar icon's rendering or icon-related settings must be mirrored in the Dock icon in the same change. Do not leave the Dock on a default or stale representation.
- When adding or changing an icon option, update both paths end-to-end as applicable: `SettingsStore` option derivation, `StatusBarController` subscriptions, `AppIconController` subscriptions/state, `DockIconRenderKey` cache inputs, `DockIconRenderer` rendering, and tests covering both menu bar and Dock output.
- If a setting is intentionally menu-bar-only, the issue or specification must say so explicitly, and the limitation must be documented and covered by a test.

## System Settings Pane Routes

- Every settings control must open the pane it promises, with that pane's own extension identifier first: the Wi-Fi gear goes to the Wi-Fi pane, and a wired row's gear goes to the Network pane, which is where a cable's own settings live. The Network pane lists services (Wi-Fi, Ethernet, VPNs) rather than networks, so routing the Wi-Fi gear through it lands users on the wrong list.
- Never make a pane route depend on the running macOS version. Wi-Fi has its own Settings extension on every release the app supports, and the `majorVersion >= 27` guard that shipped in 1.2.0 and 1.3.0 sent macOS 15 through 26 to the Network pane. See [System Settings pane routes](docs/settings-pane-routes.md).
- The first route decides the destination: System Settings launches even for an unknown pane identifier and `open` still reports success, so a wrong first route is never corrected by the entries after it — the later entries only cover the URL scheme itself failing to open.
- Verify a route by the Settings extension it loads, not by `open`'s exit status: `pgrep -fl "ExtensionKit/Extensions"` right after opening the URL names the pane, and needs neither a screen-recording nor an accessibility grant.
- `StatusMenuBuilderTests.testSystemSettingsURLFallbackOrder` pins the Wi-Fi route order. Update it with the route, never around it.
- A merged fix is not a shipped fix. When a pane-route report comes in, read the route order out of the shipped binary (`strings` on the app executable) before assuming the fix is in the build.

## Release Rules

- GitHub Release notes must use a top-level `# Version X.Y.Z （English + 中文， 中文在下方）` heading, followed by English notes and then Chinese notes, taken from `release-notes/<version>/en.md` and `release-notes/<version>/zh-Hans.md`; the release workflow combines them.
- Sparkle appcast items are localized per language: emit one `<title xml:lang="…">` and one `<description xml:lang="…">` for every language present in `release-notes/<version>/`, give every variant an explicit `xml:lang`, and keep `en` first because Sparkle falls back to the first node in document order when the user's preferred languages match nothing. Never stack two languages inside one `<description>`.
- User-facing release notes live in `release-notes/<version>/<language>.md`, one file per language the app ships (`Sources/StatusTrioCore/Resources/*.lproj` names, case-sensitive). `en.md` and `zh-Hans.md` are always required and also form the GitHub Release body; `publish=true` additionally requires all 12 languages. Every file starts with a `# <title>` line containing the `%VERSION%` and `%BUILD%` placeholders. Terminology must match the language's existing `.lproj` strings. `bash scripts/validate-appcast-notes.sh` checks coverage and the generated appcast XML, and the release workflow runs it on every dispatch, including `publish=false` preflights.
- GitHub Release bodies must append the first-launch commands `xattr -dr com.apple.quarantine "/Applications/Status Trio.app"` and `open "/Applications/Status Trio.app"` after the bilingual notes. Do not include these commands in the Sparkle appcast.
- Release announcements remain in English.
- Release through `.github/workflows/release.yml`; do not publish manually unless the workflow is unavailable and the user explicitly asks for a manual fallback.
- Version and build numbers must be explicit and must increase the published build number.
- Confirm tests, DMG creation, Release upload, and appcast publication in the workflow result.
- Sparkle currently signs the downloadable DMG entries with `sparkle:edSignature` and pins `SUPublicEDKey`; the appcast document itself does not enable `SURequireSignedFeed` or `SUVerifyUpdateBeforeExtraction`. Do not describe the feed as signed or add feed-signing claims without changing and testing that contract together.
- The release workflow accepts optional Developer ID and notarization secrets. When those secrets are absent, the artifact is Ad-hoc signed and not notarized; user-facing release notes must describe the actual workflow result and must not imply notarization from a successful build alone.

## Project Skills

- Skills live in `.agents/skills/<skill-name>/`, and the directory name must match the skill's frontmatter `name`. `skills-lock.json` at the repository root records the upstream GitHub source of each vendored skill.
- Update them from the repository root with `npx skills update -p -y`. The project path re-installs from source instead of diffing hashes, so the run is idempotent but always rewrites files — review with `git diff` before committing. The lock covers 24 of the 25 skills; `ui-ux-pro-max` is intentionally excluded.
- Do not add `ui-ux-pro-max` to `skills-lock.json`. `npx skills add nextlevelbuilder/ui-ux-pro-max-skill` resolves to the repository's own `.claude/skills/ui-ux-pro-max` variant — a thin orchestrator that delegates to six sub-skills this project does not vendor — whereas the copy here is the render of `src/ui-ux-pro-max/templates/base/skill-content.md` for the `.agents` layout, produced by the vendor's `uipro` CLI. To update it, re-render that template and take `src/ui-ux-pro-max/{data,scripts}`; never sync `.claude/skills/`.
- `npx skills update -p` skips `swiftui-pro` and `swift-testing-pro` because both upstream repositories ship two skills under the same name (`<skill>/SKILL.md` and `<skill>/skills/<skill>/SKILL.md`), which makes the target path ambiguous. Update those two by hand.
- When re-vendoring by hand, sync each whole upstream skill folder rather than `SKILL.md` alone, and delete files the upstream removed.

See [Swift toolchain CI compatibility](docs/swift-ci-compatibility.md) for the incident history and examples, and [System Settings pane routes](docs/settings-pane-routes.md) for how a settings-pane route is verified.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- For codebase questions, run `graphify query "<question>"` when graphify-out/graph.json exists; narrow broad queries and prefer `graphify explain "<symbol>"` for callers and focused concepts. Treat `graphify path` as a candidate: this graph misses the verified call from `StatusPopoverView.swift` to `StatusMappings.wifiBars`, while `--undirected` finds an unrelated detour. Verify important relationships against source.
- For file-to-file call paths, use `python3 scripts/graphify-file-path.py <SOURCE_FILE> <TARGET_FILE>`; use Graphify `path` for symbol-to-symbol paths.
- When Graphify reports duplicate-node warnings, run `graphify diagnose multigraph --graph graphify-out/graph.json --json`; assess missing endpoints and same-endpoint edge collapse from its summary, not warning count alone.
- When Graphify reports Swift parse errors, confirm with the project Swift compiler before changing app code; tree-sitter may flag syntax the Swift compiler accepts.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
