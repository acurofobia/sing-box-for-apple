# Priority failover: verification and physical memory experiment

## Acceptance status

Implementation and deterministic/transport verification are complete. **Physical-device memory acceptance is incomplete.** No simulator footprint or synthetic analyzer fixture is presented as a hardware measurement. The table below must be populated from actual packet-tunnel CSVs before making a memory, battery, sustained-growth, or OOM claim.

The development app was built, installed, and launched on the physical iPhone. CoreDevice confirmed pairing, Developer Mode, available developer services, and successful unlock. Instruments initially listed the device offline; it subsequently listed the connected device online. The fixed baseline VPN started on the physical device, confirmed by the device owner and a CoreDevice process inventory of the sing-box packet-tunnel extension (PID 2713). Its explicit memory capture was confirmed by the device owner and visible in DeviceHub. DeviceHub displays the physical screen, but its coordinate input fails with `noWindowsAvailable`; import/start actions have been handed to the device owner. The initial filtered CSV lookup returned no file, and one CoreDevice lookup timed out. The device owner then explicitly confirmed starting capture. DeviceHub shows the one-server profile, automation off, capture confirmation, and the default phase label `primary`. A targeted CSV copy identified the transport limitation: CoreDevice restricts root-level app-group files to Library/Documents/tmp. The running first baseline therefore needs app ShareLink export; its original phase label is recorded as `primary`, while its experimental role is one-server baseline.

## Conditions and artifacts

| Item | Observed value |
| --- | --- |
| Device | Physical iPhone 13 (`iPhone14,5`) |
| OS | iOS 27.0 |
| App baseline | `cd7b5d5239b5fdee71ac2525ee6c1b4118bb19f8` |
| Core baseline | `af6e64c3b69e6132ebaee0e1a3d24e93903f6709` plus saved probe and feature patches |
| Build | Signed iOS Debug development build, app version 1.14.6 (1) |
| Framework | Pinned gomobile/gobind v0.1.12, current installed Go 1.27; iOS device and simulator slices rebuilt |
| Network | Wi-Fi indicator visible; connection details and controlled workload not yet established |
| Rule-set/cache state | Not yet verified on device; uncached startup verified with a local SOCKS/HTTP integration fixture |
| Original device profile | Retained; no profile deletion or production-server changes |
| Private profiles | Ignored `build/priority-failover-private/one-server-baseline.json` and `four-servers.json`, matching `.bpf` exports, mode 0600 |
| Device import files | Copied to the existing app-group FileProvider directory `Library/Caches/Working/`; available through Files → Browse → sing-box (also retained in app Documents) |

Both exported files use the profile name `Priority Failover Test`; the supported importer assigns a unique name when necessary. Identify them by filename and import the baseline first. The baseline keeps the same routes, DNS, rule sets, download detours, and cache options, with only the primary in `proxy` and automation disabled. The four-server profile preserves the primary, converts the three supplied Xray nodes, and routes only existing proxied references through `proxy`. The attachments omit REALITY short IDs for the backup nodes; their converted value is explicitly empty. Private conversion assertions and Libbox validation passed; real VLESS/REALITY connectivity remains to be checked on the device.

## Metric and capture procedure

`Library/Network/PriorityFailoverMemoryCapture.swift` reads `TASK_VM_INFO.phys_footprint` inside the packet-tunnel process. The linked sing dependency's Darwin `memoryTotal()` uses the same metric when available. These are process physical-footprint bytes, not Go heap allocation, foreground-app memory, or RSS.

Sampling is Debug-only, starts only through an explicit connected-extension message, and streams one row per second to the app-group file. Requests accept only known phases and 1–3600 samples. A subsequent capture cancels and joins the preceding task; tunnel shutdown does the same. No unbounded sample history is stored in RAM. CSV columns are:

```text
elapsed_seconds,phase,selected,metric,unit,footprint_bytes
```

Select the phase in the imported profile's editor, start `Capture Extension Memory (12 min)`, and keep the intended workload constant. Export the CSV after capture. The first 120 seconds are warm-up; the remaining approximately 600 samples supply steady-state median and p95. Peak includes warm-up. Preserve private device artifacts under ignored `build/`; exports must not contain configuration text or credentials.

| Required experiment | Duration | Median / p95 / peak | Result |
| --- | --- | --- | --- |
| One-server baseline, automation off | 2 min warm-up + 10 min | Not measured | Capture started; CSV export pending |
| Four servers, healthy primary | 2 min warm-up + 10 min | Not measured | Pending |
| Primary down, backup healthy | 10 min | Not measured | Pending |
| All four down | 10 min | Not measured | Pending |
| At least 20 failure/recovery transitions | Transitions + 5 settled min | Not measured | Pending; one 12-minute run is insufficient at default thresholds |
| Background/locked screen, Wi-Fi/cellular | Document each condition | Not measured | Pending |

For the transition run use explicit bounded capture requests up to 3600 seconds, with the same live controller throughout. Classify actual transport faults separately from injected controller results. Repeated service restarts do not establish the required continuous-transition memory result. No production servers should be disabled. Attach Instruments to the packet-tunnel executable `Extension`, separately from the foreground app, and retain the trace in ignored storage. Document the chosen template and actual metric before comparing it with CSV footprint.

Analyze actual files with:

```sh
python3 scripts/analyze_priority_failover_memory.py build/priority-failover-private/priority-failover-memory-baseline.csv
python3 scripts/analyze_priority_failover_memory.py build/priority-failover-private/priority-failover-memory-primary.csv --baseline-bytes <measured-baseline-median>
```

The analyzer uses nearest-rank p95, rejects empty/nonfinite/negative samples, nonmonotonic time, invalid phases and other metric/unit combinations, and caps input at 86400 rows. Report baseline deltas, settled footprint, observed selection/recovery times, restarts and OOM events from the recorded experiment. No safe universal memory limit follows from a single device.

## Executed verification

- `go test -race ./daemon ./experimental/libbox ./protocol/group -count=1` passed for both the working core and a freshly archived upstream with the saved probe patch followed by the final feature patch. Real local SOCKS/HTTP fixtures require loopback access outside the default sandbox.
- Tests cover priority and ordered backups, failure/recovery hysteresis, all-down, manual selection during a probe, external selector/Clash selection, pause/resume, stop, repeated instances, bounded counters, and serialized probes.
- Real transport fixtures cover response validation, cancellation, a hung first health endpoint with successful second endpoint, and uncached rule-set fetch through a selected healthy backup before router initialization.
- `SING_PRIORITY_PRIVATE_DIR=... go test -tags with_utls ./experimental/libbox -run TestPriorityPrivateConfig -count=1` passed for both private profile artifacts without printing their contents.
- `python3 -m unittest discover -s scripts/tests -p 'test_priority_failover_memory.py'` passed (3 tests). Synthetic values are analyzer verification only.
- Final `xcodebuild build ... -scheme SFI -configuration Debug -destination 'generic/platform=iOS'` passed; CoreDevice install and launch succeeded.
- Native model/bridge tests passed. The settings UI was rendered and inspected on the iOS 27 simulator; enabled settings displayed all four tags, ordered backup controls, and the 10 s / 5 s / 2 / 3 defaults. The final persistence UI test passed separately (one test, zero failures, `TEST EXECUTE SUCCEEDED`); four model/bridge/remote-target contract tests passed in the preceding run. The test toggles the actual switch control, scrolls to the saved confirmation, reloads the app, verifies enabled fields, and disables/saves the policy. Official screenshots are in ignored `build/priority-failover-ui-evidence-final/`.
- Native test coverage was disabled because the existing PLCrashReporter product failed to link the coverage runtime; no dependency or version was changed.
- Root and upstream `git diff --check` passed. SwiftFormat, SwiftLint and xcbeautify are absent from PATH, so their checks were not run. macOS/tvOS builds were not run and those framework slices were not regenerated.

Detailed local logs are `/tmp/sing-priority-final-core-tests.log`, `/tmp/sing-priority-applied-patch-tests.log`, `/tmp/sing-priority-private-validation.log`, `/tmp/sing-priority-final-framework.log`, `/tmp/sing-priority-final-device-build.log`, `/tmp/sing-priority-verified-native-tests.log`, and `/tmp/sing-priority-final-ui-tests.log`. The framework builder's output basename must be `Libbox.xcframework` to preserve the generated module name. The previous framework was retained in ignored build storage until the replacement succeeded.

## Final review dispositions

One independent read-only review was performed. No Critical findings were reported. Every material finding was addressed with reproducing tests:

| Finding | Ruling and evidence | Consequence if left wrong |
| --- | --- | --- |
| First health endpoint consumes the entire deadline | Fixed: each serial attempt receives a share of the remaining total deadline; hanging-first/204-second transport test passes | Healthy proxies falsely classified down |
| Remote Groups controls a local controller | Fixed: local status/resume is suppressed for remote targets; native remote-target guard test passes | Wrong VPN changed by the displayed remote UI |
| Manual selection retains all-down/health observations | Fixed: clear all-down and mark primary health unknown when entering manual mode; controller test passes | Persistent false outage indication |
| Failure/recovery counters grow indefinitely | Fixed: saturate counters at their thresholds; deterministic test passes | Unbounded state/overflow over long runs |
| Initial unpaused callback queues an extra startup cycle | Fixed: only an actual pause/resume transition wakes work; deterministic test passes | Extra probes or bypassed recovery hysteresis |
| Clash API bypasses manual mode | In scope and fixed: selector external-selection handler enters manual mode; automatic selections use the internal bypass; integration test passes | External manual choice overwritten automatically |

The reviewer explicitly declined the following judgments; none is silently treated as acceptance:

1. **Hardware footprint/growth/battery/OOM/lock/network behavior:** remains unresolved pending the table above. Incorrect inference could hide extension termination or regressions.
2. **Native visuals/accessibility/signing:** simulator screenshots/UI verification and physical build/install provide separate evidence; complete physical interaction remains pending. Incorrect inference could hide unusable controls on-device.
3. **Private conversion/routing/DNS:** separately validated against the supplied local artifacts and Libbox, with no secrets exposed. Transport acceptance remains pending; errors could break routing or authentication.
4. **Existing probe and unrelated baseline:** deliberately preserved and excluded from the new feature patch. New Libbox package tests also run the saved probe tests; no unrelated refactor is claimed.
5. **Framework provenance/platform completeness:** pinned tools and iOS/simulator rebuild verified; macOS/tvOS are unverified. Do not ship a different platform on the strength of this iOS result.
6. **Clash manual boundary:** explicitly included and fixed as described above.
7. **Manual-mode persistence across restart:** deliberately session-scoped. A new service establishes primary preference afresh, as required by the approved startup behavior; a restart is not an implicit persisted manual choice.
8. **Public endpoint availability and production VLESS/REALITY behavior:** local transport and private syntax checks provide no production reachability proof. Both public probe endpoints being unavailable can still produce an all-down observation, with bounded intervals and no direct fallback.

Changes remain uncommitted. No push, merge, additional commit, production configuration change, or new worktree was performed.

## Baseline startup follow-up

The device owner imported the original baseline and confirmed it was selected with Only VK TURN disabled, but the app started VK TURN. The existing app preflight treats initialization failure as a failed sing-box check and chooses VK TURN. A host reproduction found rule-set `geosite-epic-games` returned 404 during initialization, before the health request. The [official release directory](https://github.com/hydraponique/roscomvpn-geosite/tree/master/release/sing-box) contains `epicgames.srs`. Direct HTTP checks returned 404 for `epic-games.srs` and 200 for `epicgames.srs`.

Separate ignored `one-server-baseline-fixed.json/.bpf` and `four-servers-fixed.json/.bpf` change only that filename in the public rule-set URL; their routing, DNS, proxy parameters, rule-set tags and cache settings otherwise remain identical to the original converted artifacts. Original artifacts and device profiles were retained. Fixed baseline passes the same 10-second Libbox preflight on the Mac in 2.72 seconds; this is connectivity evidence, **not iPhone memory evidence**. The fixed files were copied to FileProvider with import names `Priority Baseline Fixed` and `Priority Four Servers Fixed`. The device owner subsequently confirmed successful on-device startup of sing-box with the corrected profile; baseline capture has started, and its export and remaining physical phases are pending.

The original app preflight did not receive the failover policy and could choose VK TURN before the extension controller started when the primary was down. The follow-up below addresses this gap; full physical cold-launch behavior still requires verification with a controlled unavailable primary.

Provider preflight follow-up: the enabled per-profile policy is now forwarded to a bounded, one-shot Libbox preflight. It uses the same daemon cold-selection hook and only `PreStart`, so a healthy backup is selected before remote rule-set initialization without starting TUN or periodic probing. Disabled-policy profiles keep the existing preflight. The local dead-primary/healthy-backup/uncached-rule-set and all-down tests pass under the race detector (`/tmp/sing-priority-provider-preflight-green.log`). The updated iOS/simulator framework was rebuilt and its generated bridge headers verified. The signed physical-device app build passed (`/tmp/sing-priority-preflight-device-build.log`). Five native bridge/model/remote-target tests passed with TEST EXECUTE SUCCEEDED (`/tmp/sing-priority-preflight-native-final-tests.log`). The bridge fixture explicitly sets up Libbox in an isolated temporary directory; its initial omission caused a test-only cache ownership failure, then was corrected. Parallel simulator cloning was disabled after a CoreSimulator clone-creation error. The installed device build still predates this follow-up.

Physical capture follow-up: moved future Debug CSV output and ShareLink together into the existing shared cache directory (`Library/Caches`) accessible to CoreDevice, and changed the initial phase picker value to baseline. The installed build and its active capture retain the original root location; do not reinstall until the original CSV is exported.
