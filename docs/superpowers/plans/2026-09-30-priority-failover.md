# Priority Failover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task after the user's plan review. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep one preferred server and three ordered backups in a single sing-box profile, with bounded health checks and physical-iPhone memory measurements.

**Architecture:** Keep the four concrete outbounds and a standard selector in the configuration. A controller owned by the running Libbox instance executes inside the VPN extension process; the app supplies per-profile policy through the existing start-options snapshot. Select a healthy server at the outbound-ready startup stage, before remote rule-set downloads, and use the same controller for ongoing checks.

**Tech Stack:** Existing SwiftUI/GRDB/BinaryCodable app, NetworkExtension, Go 1.25.5 sing-box source, existing gomobile build tooling, XCTest, and Xcode Instruments.

**Spec:** `docs/superpowers/specs/2026-09-30-priority-failover-design.md`

**Execution status:** Executed inline in the current checkout after user approval. Controller, bridge, per-profile UI/IPC, private conversion, bounded diagnostics and analyzer are implemented. Automated verification and one independent final review completed; material findings fixed. Physical memory capture and on-device behavior remain incomplete pending baseline import/VPN start. See `docs/testing/priority-failover-memory.md` and the execution ledger; no additional commit or push was made.

## Global Constraints

- One preferred server and three ordered backups in one profile.
- A healthy primary must remain selected regardless of latency.
- Existing VPN provider selection, including VK TURN, must remain unchanged.
- Never place real endpoint credentials in repository documents, fixtures, logs, or test traces.
- Unconfigured profiles retain their existing behavior.
- At most one probe is active at any moment.
- Per-probe deadline: 5 seconds.
- Failover threshold: two consecutive failed active-server checks.
- Return after three consecutive successful primary checks.
- Never route proxied traffic through `direct` as a fallback.
- No dependency upgrades or production-server modifications.
- Baseline commit explicitly requested by the user is `cd7b5d5`. Do not create subsequent commits, push, merge, or discard changes without further authorization.
- Work in the current checkout so the saved local core patch remains available. Do not create an isolated checkout that drops this source state.

## Review Focus

1. Cold startup with no rule-set cache and a dead primary must reach a healthy backup before rule-set fetches.
2. A manual group selection during a pending automatic probe must win until automation is explicitly resumed.
3. Stop, reload, pause, and repeated start must cancel checks and prevent old instances from selecting a server.
4. Both probe URLs unavailable while the VPN server is healthy must not cause rapid oscillation or direct fallback.
5. Editing or remotely updating a profile must validate tag membership before enabling an obsolete policy.

## Baseline Evidence

- `xcodebuild build -skipPackagePluginValidation -scheme SFI -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData` exited 0 with `BUILD SUCCEEDED`.
- `GOCACHE=/private/tmp/sing-failover-go-cache go test ./experimental/libbox -run 'TestProbe' -count=1` exited 0.
- Baseline parent commit includes `.gitmodules`, the upstream revision, and the existing complete probe patch. The upstream checkout intentionally still has that patch applied.
- Existing `daemon.StartedService.URLTest` starts asynchronous work and returns before completion; do not interpret its command return as probe success.
- Existing `ProbeConfig` constructs a temporary box; do not use it for periodic health checks.
- The Xcode project references `upstream/sing-box/Libbox.xcframework`.
- Darwin `common/memory.memoryTotal()` in the current sing dependency returns `TASK_VM_INFO.phys_footprint` when available. Verify the compiled iOS build uses this path and distinguish it from Go heap allocation metrics.
- Physical iPhone 13 is paired and available in CoreDevice; Instruments last listed it offline. Hardware profiling connectivity must be verified again at execution time.

## Files and Responsibilities

- `upstream/sing-box/daemon/priority_failover.go`: validated policy and instance-owned serialized selection controller.
- `upstream/sing-box/daemon/priority_failover_test.go`: deterministic behavior and lifecycle tests.
- `upstream/sing-box/daemon/instance.go`: construct and close the controller with its existing box.
- `upstream/sing-box/daemon/started_service.go`: distinguish external manual selection from automatic switching.
- `upstream/sing-box/box.go`: optional outbound-ready callback before route initialization, with no effect when unset.
- `upstream/sing-box/experimental/libbox/priority_failover.go`: binding-compatible metadata, policy, and bounded-probe bridge.
- `upstream/sing-box/experimental/libbox/priority_failover_test.go`: bridge/config validation and local transport integration tests.
- `upstream/sing-box/experimental/libbox/command_server.go`: carry policy from override options and expose controller actions.
- `patches/sing-box-priority-failover.patch`: reproducible feature diff against the existing upstream checkout, excluding the already-saved probe patch.
- `Library/Network/PriorityFailoverConfiguration.swift`: Codable policy and metadata types.
- `Library/Database/SharedPreferences.swift`: per-profile policy storage using the existing Preference mechanism.
- `Library/Database/SharedPreferences+Database.swift`: a throwing policy write/delete path that reports persistence failures.
- `Library/Network/ExtensionProfile.swift`: load and validate policy, pass start options, and send explicit controller commands.
- `Library/Network/ExtensionProvider.swift`: apply policy on start/reload and handle typed status/manual/resume requests before the existing reload-message path.
- `ApplicationLibrary/Views/Profile/PriorityFailoverSettingsView.swift`: bounded settings section reusing existing form/picker components.
- `ApplicationLibrary/Views/Profile/EditProfileView.swift`: host the section.
- `ApplicationLibrary/Views/Groups/GroupListView.swift`: display automatic/manual state and resume action using the existing selected-group data.
- Existing `Localizable.xcstrings`: strings for new settings and states.
- `UITests/PriorityFailoverTests.swift`: native configuration and manual-mode coverage in the existing test target.
- `docs/testing/priority-failover-memory.md`: commands, conditions, measurements, and limitations from the physical-device experiment.
- `scripts/analyze_priority_failover_memory.py`: standard-library CSV statistics with explicit units and nearest-rank p95.
- `scripts/tests/test_priority_failover_memory.py`: analyzer fixtures and invalid-input coverage.

### Task 1: Policy and Serialized Controller

**Consumes:** Validated primary/backup tags, a concrete-outbound probe, a selector, an instance context, and pause events.

**Produces:** `PriorityFailoverPolicy`, an instance-owned controller, explicit automatic/manual state, and deterministic selection behavior.

- [x] Add failing policy/controller tests with an injectable probe and selection callback. The test adapter records tag, result, and maximum concurrent probes; synchronize through channels rather than wall-clock sleeps.

```go
type PriorityFailoverPolicy struct {
    Selector string   `json:"selector"`
    Primary  string   `json:"primary"`
    Backups  []string `json:"backups"`
    IntervalMilliseconds int32 `json:"intervalMilliseconds"`
    TimeoutMilliseconds  int32 `json:"timeoutMilliseconds"`
    FailureThreshold     int32 `json:"failureThreshold"`
    RecoveryThreshold    int32 `json:"recoveryThreshold"`
}

type priorityFailoverBackend interface {
    Probe(context.Context, string) (bool, error)
    Selected() string
    Select(string) error
}
```

Test exact sequences:

| Test | Probe results | Expected selection |
|---|---|---|
| `TestPriorityHealthyPrimary` | primary always succeeds; backups would be faster | primary; no idle-backup probes |
| `TestPriorityFailureThreshold` | primary failure, success, failure | primary; success resets the counter |
| `TestPriorityOrderedBackups` | primary fails twice; backup 1 fails; backup 2 succeeds | backup 2; backup 3 not probed |
| `TestPriorityRecoveryThreshold` | backup selected; primary succeeds twice, fails, then succeeds three times | return only after final third success |
| `TestPriorityAllDown` | every candidate fails | no `direct`, bounded retries, explicit all-down state |
| `TestPriorityManualDuringProbe` | pending primary check; manual backup selection | pending result cannot overwrite manual choice |
| `TestPriorityStopDuringProbe` | probe blocks until context cancelled | exit and join; no subsequent selection |
| `TestPriorityPauseAndResume` | paused during check | cancel; resume with one cycle, no accumulated ticks |
| `TestPriorityRepeatedStart` | replace instance repeatedly | maximum one live controller and one probe |
| `TestPriorityProbeEndpointsDown` | both target endpoints fail | threshold and interval respected; no oscillation loop |

- [x] Run `GOCACHE=/private/tmp/sing-failover-go-cache go test ./daemon -run 'TestPriority' -count=1`; confirm failures refer to missing feature types/behavior.
- [x] Implement policy range validation (nonempty distinct tags, exactly three backups, interval at least 1 second, timeout 1–10 seconds, nonzero bounded thresholds), and one controller loop. Schedule the next timer only after the current cycle completes. Derive all operation contexts from the instance context.
- [x] Use one mutex/serialized state owner for automatic/manual mode and a generation counter. A mode change, stop, or pause invalidates an in-flight result. Log transitions only. Store bounded counters and current state, not a growing history.
- [x] On backup operation check primary first; if recovery threshold is not met, also assess the active backup. Keep a healthy active backup until primary recovery or active failure.
- [x] Re-run the focused tests, then `go test -race ./daemon -run 'TestPriority' -count=1`; inspect actual results.

### Task 2: Running-Instance Probe, Startup Ordering, and Bridge

**Consumes:** Task 1 policy/controller; the existing outbound manager, selector, pause manager, and TLS/dialing helpers.

**Produces:** A lifecycle-safe controller in the existing instance and binding-friendly Libbox operations without changing standard config syntax.

- [x] Add bridge tests using local SOCKS and HTTP servers. Test actual transport failure separately from the controller's injected failures. Assertions include response status validation, no temporary box creation, one open probe maximum, deadline cancellation, and connection cleanup.
- [x] Add an uncached remote rule-set integration fixture pointing at a local HTTP server through `proxy`; primary is an unreachable local SOCKS endpoint and a backup is a working local SOCKS endpoint. Assert successful startup and backup selection before the first rule-set request.
- [x] Run the tests to observe the missing behavior before implementation.
- [x] Implement a direct concrete-outbound HTTP probe. Both target attempts share the same 5-second context; do not extend the deadline per endpoint. Validate the expected successful response, disable redirects, close response bodies and idle transport connections, and never use a global URLSession/default system transport.
- [x] Add an optional hook to `box.Options`:

```go
OnOutboundsReady func(context.Context) error
```

Store it on `Box` and call it after outbound, DNS transport, network, connection, and HTTP-client startup, immediately before the router/DNS-router start in `Box.preStart`. For unconfigured instances leave it nil. Do not call `PreStart` followed by `Start`, which would repeat initialization.

- [x] Construct the controller on the same `daemon.Instance`, validate selector membership, and bind the hook to an initial bounded health selection. Start periodic work only once startup succeeds. Cancel/join before `Instance.Close`; propagate startup interruption to the probe context. Cover cached backup selection by explicitly establishing preferred-server health at startup.
- [x] Pass a validated optional policy through `daemon.OverrideOptions` and binding-friendly `LibboxOverrideOptions.priorityFailoverJSON`. Add metadata extraction using Libbox's own `parseConfig`, retaining supported JSON comments.

Bridge contracts:

```go
func PriorityFailoverMetadata(configContent string) (string, error)
func ValidatePriorityFailover(configContent, policyJSON string) error
func (s *CommandServer) PriorityFailoverStatus() (string, error)
func (s *CommandServer) ResumePriorityFailover() error
```

Metadata JSON contains selector tags, their concrete candidate tags and defaults, and concrete outbound display types; never return credentials. Status JSON contains mode, selected tag, primary health, and all-down state. Failover-disabled status is explicit, not an error.

- [x] External `StartedService.SelectOutbound` for the configured group enters manual mode and invalidates automatic work before changing the selected tag. Controller-owned selections call the validated selector internally and remain automatic. Resume triggers a bounded preferred-server health cycle.
- [x] Reject unknown/nested/direct tags and outdated selector membership before teardown of a working service. Validate an edited/updated config on save and again on start.
- [x] Run focused Go tests and race tests for the new code. Generate `patches/sing-box-priority-failover.patch` only from files in this task/Task 1; exclude existing `config.go`/`config_probe_test.go` changes.
- [x] Build the Apple framework using the existing `go run ./cmd/internal/build_libbox -target apple -platform ios` workflow after verifying the tool's platform handling. Preserve the previous framework until the new build succeeds; install into the Xcode-referenced upstream path. Check the generated Objective-C headers contain the new methods and override field.

### Task 3: Per-Profile Settings and Extension Transport

**Consumes:** Task 2 bridge, metadata/status JSON, and start-option override field.

**Produces:** Persisted validated policies, native settings, background-safe startup, and manual/resume control.

- [x] Add failing native tests for enabled/disabled policy loading, tag validation, comment-bearing config parsing via Libbox, missing backups after remote update, and preservation of ordinary profiles.
- [x] Add the Codable policy corresponding exactly to Task 1 fields. Reuse the existing preference table with the per-profile key:

```swift
public static func priorityFailover(_ profileID: Int64)
    -> Preference<PriorityFailoverConfiguration?> {
    Preference("priority_failover_\(profileID)", defaultValue: nil)
}
```

Use a throwing save path for the settings so a database write failure cannot appear as a successful save. Delete the policy with a deleted profile. No schema migration or new persistence dependency is needed.

- [x] Add the profile editor section: enabled toggle, selector picker, primary picker, ordered backup rows with move controls, and validation/loading/error/empty states. Derive candidates from Libbox metadata rather than hardcoding user tags. Set defaults to 10000 ms/5000 ms/2 failures/3 recovery successes.
- [x] Validate both profile JSON and policy before writing settings. Keep unsupported metadata outside the config. Save configuration explicitly; do not overwrite a remote subscription with a synthesized local file.
- [x] In `ExtensionProfile.prepareStartOptions`, snapshot the enabled policy as JSON with the existing `configContent`. In `ExtensionProvider.startService`, forward it through the new override field. Missing policy keeps current startup behavior.
- [x] Dispatch typed controller requests before treating app messages as reload options:

```swift
struct PriorityFailoverRequest: Codable {
    enum Action: String, Codable { case status, resume }
    let kind: String // "priorityFailover"
    let action: Action
}
```

Return structured errors/results, validate the discriminator/action, and preserve the existing reload path for all other messages. Resume should update the live controller without reloading the service.
- [x] Reuse group selection display; add automatic/manual/all-down status and a resume button. Query status only while the screen is visible using bounded refresh; cancel on disappearance. Core selection events continue using existing group notifications.
- [x] Add English source strings and Russian translations to the existing catalog. Code and comments remain English.
- [x] Run the new native tests and an iOS build. Run SwiftFormat/SwiftLint on the touched sources using installed project tools, or report tool absence; do not broadly reformat unrelated sources or install dependencies silently.
- [ ] Verify settings, manual selection, resume, validation errors, and background behavior in the native iPhone app. Add the affected UI tests to the existing test target and run them when supported.

### Task 4: Private Four-Server Profile and End-to-End Behavior

**Consumes:** Completed Tasks 1–3 and the two supplied private config attachments.

**Produces:** A private ready-to-import four-server profile, validated policy, and demonstrated failover behavior.

- [x] Use the latest sing-box profile as the base. Preserve `R3-N1`; convert Xray outbounds `CROSS_R2_N4`, `CROSS_R2_N3`, and `CROSS_R1_N4` to three concrete VLESS outbounds, preserving each one's port, UUID, flow, SNI, uTLS fingerprint, and REALITY key parameters. Keep real values out of terminal output.
- [x] Add selector `proxy` with the four tags, primary default, and interruption enabled. Rewrite only existing proxied route references, final route, and rule-set download detours to `proxy`; leave DNS, direct, and reject behavior intact.
- [x] Write the converted artifact to `build/priority-failover-private/` (already ignored) and check it with Libbox. Prepare a one-server baseline artifact with exactly matching routes/rule sets/cache behavior and automation disabled. Never commit these artifacts or include their raw contents in a shared report.
- [ ] Install a development app build on the paired physical iPhone through Xcode/CoreDevice. Import the profile through supported app UI; retain the user's existing profile for restoration. Set the policy through the new settings.
- [ ] Exercise healthy primary, preferred backup order, primary recovery, all-down, manual override/resume, app backgrounding, reload, and uncached startup. Simulate failures with private local endpoints or a DEBUG-only bounded test adapter; never change production servers. Record which scenarios use actual transport failures and which use injection.
- [ ] Confirm direct-rule traffic retains its previous behavior and proxied traffic never chooses `direct` during all-down. Restore ordinary profile/settings after diagnostics.

### Task 5: Physical-Device Memory Capture and Final Review

**Consumes:** The development build/profile from Task 4, the iPhone 13, status footprint samples, and Instruments traces.

**Produces:** A reproducible measurement report with actual hardware numbers or an explicit unresolved profiling limitation.

- [x] Verify the device is available to both CoreDevice and Instruments. If profiling remains offline, diagnose pairing/unlock/Developer Mode using the existing Xcode tooling. Ask for a required physical action only after completing independent work; never substitute simulator memory results.
- [x] Add bounded diagnostics for memory sampling, with phase/selected tag/time/footprint in a CSV. Stream records to disk and cap the diagnostic duration; do not keep every sample in RAM. Keep the diagnostic disabled outside an explicit test run. Existing Libbox status sampling can supply Darwin footprint.
- [x] Add analyzer tests to `scripts/tests/test_priority_failover_memory.py`, run them to observe the missing implementation, then implement `scripts/analyze_priority_failover_memory.py` and rerun `python3 -m unittest discover -s scripts/tests -p 'test_priority_failover_memory.py'`. Function contracts are `median(samples: list[float]) -> float` and `percentile(samples: list[float], quantile: float) -> float`. Use a known synthetic fixture before interpreting hardware data:

```python
samples = [10, 20, 30, 40, 50]
assert median(samples) == 30
assert percentile(samples, 0.95) == 50  # nearest-rank definition
assert max(samples) == 50
```

Reject empty/nonfinite/negative samples and mixed metric units. Report peak separately from steady-state statistics; discard only the documented warm-up.

- [ ] Record model, iOS version, build/core revisions, signing/build configuration, network, cache state, and controlled traffic workload. Attach Instruments to the packet tunnel extension, separately from the foreground app. Keep credentials and endpoint details out of trace/report exports.
- [ ] Run matched 2-minute warm-up + 10-minute capture for one-server baseline and four-server healthy-primary operation.
- [ ] Capture 10 minutes with primary down/backup healthy, and 10 minutes with all four down. Verify one active check maximum and no accumulation of waiting work.
- [ ] Capture at least 20 controlled failure/recovery transitions, followed by 5 settled minutes. Run background/locked-screen and Wi-Fi/cellular scenarios. Record real-versus-injected failure distinctions.
- [ ] Compute median, p95, peak, baseline delta, settled footprint, selection/recovery times, and observed OOM/restarts. Do not infer a universal safe MB limit from one device.
- [x] Write `docs/testing/priority-failover-memory.md` with the measured table, commands actually run, metric definition, artifacts, outcomes, and limitations. If hardware capture cannot complete, clearly mark that requirement incomplete.
- [x] Run final focused Go/native tests, iOS build, formatting/lint where available, and review the complete feature diff against `cd7b5d5`. Include upstream source diff and saved patch in the review. Follow the executing-plans final-review workflow; fix material issues with reproducing tests before claiming completion.
- [ ] Report baseline commit, implementation scope, executed checks, physical-device measurements, and remaining limitations. Do not make an additional commit or push without an explicit request.

## Plan Self-Review

- All five Review Focus conditions have owning test scenarios in Tasks 1–3.
- Cold-start selection occurs before router initialization; `PreStart` is not repeated.
- Policy is carried as application metadata, with standard sing-box JSON preserved.
- Manual selection is intercepted at the core boundary, including existing group controls.
- Probe and controller contexts belong to the same instance and are joined at shutdown.
- No secrets are embedded in this plan, the source fixtures, or expected reports.
- Physical iPhone profiling is required and is not represented as already performed.
- Only the pre-feature baseline commit is authorized; implementation remains reviewable and uncommitted.
