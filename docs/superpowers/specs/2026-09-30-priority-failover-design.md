# Priority failover for sing-box profiles

## Intent and scope

The user wants one preferred sing-box server and three ordered backups in one
profile. A healthy primary must remain selected regardless of latency. The user
approved the selector-based design and explicitly requires memory measurements
on a physical iPhone. Existing VPN provider selection, including VK TURN, must
remain unchanged. No commits, pushes, or production server changes are authorized.

This is a new subsystem spanning profile settings, the tunnel lifecycle, and the
Libbox bridge. This document records the agreed behavior before implementation.

## Configuration

- Keep a single standard sing-box JSON configuration with four VLESS outbounds,
  a selector named `proxy`, and the existing `direct` outbound.
- Keep `R3-N1` from the latest supplied sing-box configuration as the primary.
- Use `CROSS_R2_N4`, `CROSS_R2_N3`, and `CROSS_R1_N4` from the supplied Xray
  configuration as the three backups, in that order. This mapping preserves the
  current sing-box primary and the previous backup order. The old Xray primary
  is a different endpoint and is not silently added as a fifth server.
- Convert only the three backup endpoint definitions into sing-box VLESS/TLS/
  REALITY settings. Preserve the current primary's parameters.
- Set selector `default` to `R3-N1` and `interrupt_exist_connections` to true.
- Replace references to `R3-N1` in proxied route rules, `route.final`, and
  remote rule-set `download_detour` with `proxy`.
- Preserve existing DNS behavior and all explicit `direct`, sniff, DNS hijack,
  and reject rules. Do not silently change the DNS server's dial path.
- Store failover policy separately as per-profile application settings; do not
  insert unsupported keys into the standard sing-box configuration.
- Validate the actual config through Libbox, using its JSON parsing conventions,
  including supported comments. Policy validation rejects unknown tags, direct
  outbounds, nested groups, duplicates, and a selector that does not contain
  exactly the configured primary and backups.
- Never place real endpoint credentials in repository documents, fixtures, logs,
  or test traces. A converted private config must be kept outside version control.
- Unconfigured profiles retain their existing behavior.

## Runtime architecture

The controller runs inside the packet tunnel extension. The foreground app is
only responsible for configuration and displaying current group selection.

Use the existing running sing-box instance for every health probe. Do not invoke
the existing `ProbeConfig` function, which constructs another temporary box.
The existing `URLTest` command returns before its asynchronous probe finishes;
its command success is not evidence that the server is healthy.

Add a small Libbox bridge for a bounded probe of a named concrete outbound in
the running service. It must return an explicit success/failure result, resolve
the requested outbound directly, and never change selector membership or its
selection merely to probe a backup. Reuse sing-box's dialers and TLS machinery.
Use a GET/HEAD request with an expected successful probe response, a deadline,
and deterministic connection cleanup; an arbitrary HTTP error is not health.
Service shutdown, pause, or reload cancels active probes and invalidates their
results. Serialize lifecycle operations so no probe accesses a closed instance.

Reuse the existing selector switching operation. Do not reload the config or
restart the tunnel when selecting a different server. Stop probes before
closing or replacing the service. Starting and reloading must not create a
second controller. A generation token prevents stale results from selecting
outbounds after a lifecycle change.

Libbox source changes must be preserved as a separate reproducible patch beside
the existing probe patch. Rebuild the framework actually referenced by the Xcode
project (`upstream/sing-box/Libbox.xcframework`); do not replace unrelated user
changes or quietly upgrade dependencies.

## Selection policy

Initial defaults, adjustable through per-profile settings:

- Primary and active outbound check interval: 10 seconds after the previous
  cycle completes. At most one probe is active at any moment.
- Per-probe deadline: 5 seconds. Try a second independent endpoint only after
  the first fails, within the same overall deadline.
- Failover threshold: two consecutive failed active-server checks. A successful
  check resets the counter. Probe errors caused by stop/pause/reload do not
  count as a network failure.
- On active-server failure, check candidates in configured priority order and
  select the first healthy candidate. Skip rechecking a candidate whose failure
  has already been established in that cycle.
- While on a backup, check the primary each cycle. Return after three consecutive
  successful primary checks. Also check the active backup while the primary is
  unavailable. Keep a healthy active backup rather than bouncing between backups
  merely because another backup recovered.
- While on the primary, do not continuously probe all idle backups; check them
  when needed for failover. This trades a bounded search delay for lower memory,
  battery, and network overhead.
- If all candidates fail, keep retrying with bounded work. Never route proxied
  traffic through `direct` as a fallback. Previously explicit direct rules remain
  direct. State shown to the user must distinguish no working proxy from a
  connected VPN tunnel.
- Explicit automatic/manual mode avoids competing with manual server selection.
  A manual choice suspends automatic selection until the user resumes it.
- At startup ignore a cached backup selection as a permanent policy decision:
  establish health and prefer the primary. Preserve ordinary cache behavior for
  profiles without failover settings.

Cold startup must also work when the primary is unreachable. In particular,
remote rule-set initialization must not prevent the controller from ever
starting. Inspect the actual startup ordering, preserve existing cached rule
sets, and arrange bounded selection at the earliest safe outbound-ready stage
if rule-set downloads otherwise depend on an unavailable primary. This case
requires a dedicated integration test.

## Settings and visibility

Add a small section to the existing profile editor:

- Enable/disable automatic priority failover.
- Choose the selector and preferred server.
- Order the backup servers.
- Validate and save policy alongside the profile; pass its snapshot with the
  existing tunnel start options so background and system-initiated starts work.

Reuse the existing groups screen to show active selection and health information.
Keep transition logs bounded and free of credentials. Log state changes and
errors, not every successful periodic check. Add user-facing strings to the
existing localization catalog. Respect existing platform compilation conditions.

## Verification

Run focused deterministic policy tests before hardware tests. Cover primary
retention despite higher latency, ordered backup choice, recovery hysteresis,
all-down behavior, stale result rejection, no overlapping probes, cancellation,
manual mode, invalid config/policy, and cached backup selection on restart.

Libbox bridge tests must demonstrate that probes use the existing instance,
honor the deadline, close connections, reject non-concrete/direct outbounds, and
cannot select a server after shutdown or reload. Use local controllable test
servers rather than real user credentials.

Run applicable Go tests and the iOS build, then format/lint changed Swift files
with project tools when available. Verify the settings in the native app; a web
browser is not an appropriate verifier for this SwiftUI application.

## Physical iPhone memory experiment

A physical iPhone 13 was discovered as available and paired on 2026-09-30 using
`xcrun devicectl list devices`. Instruments listed the same device as offline,
so profiling connectivity is not yet confirmed. Do not use simulator measurements as acceptance
evidence. Install and run a development build on this device when tooling and
signing permit. Do not alter production servers to trigger failures.

Measure the packet tunnel extension process, separately from the foreground app.
Use Instruments process footprint/allocations and the existing Libbox memory
status as complementary measurements; report which metric each number uses.
Identify what the current `memory.Total()` reports before treating it as the
operating system's footprint. Record iOS version, device model, app/core build,
build configuration, network, rule-set cache state, and workload.

Compare the following with matching rules, cache state, traffic, and build:

1. One-server baseline, automation disabled: 2-minute warm-up, 10-minute capture.
2. Four servers, primary healthy: same warm-up and capture.
3. Primary unavailable, one healthy backup: 10-minute capture.
4. All four unavailable: 10-minute capture; no accumulating pending checks.
5. At least 20 controlled failure/recovery transitions, then 5 minutes settled.
6. Background app and locked device, plus a Wi-Fi/cellular transition.

Use a private device-only test fixture or a bounded diagnostic fault-injection
mode to simulate per-server failures without editing production infrastructure.
Clearly distinguish simulated controller failures from real transport failures;
exercise both kinds where possible. Restore normal settings after the run.

Report steady median, p95, peak, change from baseline, post-transition settled
memory, observed selection/recovery time, and any OOM termination or restart.
Collect bounded samples and export a credential-free CSV/report. Instrumentation
must not build an unbounded in-memory history or retain old controller instances.

Acceptance requires correct priority behavior, no unintended direct fallback,
continued operation with the app in the background, no repeated-controller or
probe accumulation, no sustained growth across repeated transitions, and no
observed OOM termination in these scenarios. Do not claim a specific MB overhead
or safety margin until the measurements exist. If device profiling is blocked,
preserve the implementation and explicitly report that physical memory testing
remains incomplete.

## Working-tree constraints

The checkout contains extensive existing Swift, project, entitlement, Libbox,
and VK TURN changes. Preserve them. Do not commit, discard, overwrite, stash,
or migrate them into a clean checkout without user authorization. Keep the
feature diff targeted and reviewable against the starting working tree.
