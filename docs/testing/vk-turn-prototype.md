# VK TURN routing prototype

This experimental worktree uses branch `codex/vk-turn-routing-prototype` in both the application repository and its sing-box core worktree. Changes are uncommitted. The main checkout and its local UI/subscription changes are untouched. The core includes the pre-existing priority-failover changes as its source baseline.

The isolated iOS app is **VK TURN Prototype**, scheme `VKTurnPrototype`, bundle ID `ru.acurofobia.singbox.vkprototype`, app group `group.ru.acurofobia.singbox.vkprototype`, and a separate Keychain group. It embeds only the sing-box packet tunnel extension. The prototype app currently targets iOS 27 and was built with Xcode 27.0 for an iPhone 13 running iOS 27.0.1.

## Data path

`iOS packetFlow → sing-box TUN/gVisor → original route rules → native sing-box WireGuard → vk-turn-transport → VK TURN → peer`

Direct rules use sing-box direct. Reject rules remain reject. The source `route` is the only imported config section; source DNS, servers, keys and other outbound settings are not imported. Every `R3-N1` route target, including `final`, becomes `vk-wg`. Accordingly, this config also sends unmatched traffic through TURN; it is not limited to explicitly listed YouTube/GitHub rules.

Twenty-one rule sets from [RoscomVPN routing](https://github.com/hydraponique/roscomvpn-routing) are configured as native sing-box remote rule sets. The URLs use the live `release` branches of `hydraponique/roscomvpn-geosite` and `hydraponique/roscomvpn-geoip`. Downloads use `http_client.detour: vk-wg`, which is the selected WireGuard/TURN or VLESS connection. Native updates run every day while the VPN is running with routing enabled; valid updates apply to the running core.

The bundled `.srs` files under `PrototypeApp/RuleSets` remain the initial fallback. The app copies them to the app group's `Library/Application Support/PrototypeRuleSets/Initial` and writes absolute `initial_path` values. Native startup loads its persistent cache first, then the fallback, so starting the VPN does not require a successful download. The native cache is stored separately at `Library/Application Support/PrototypeRuleSets/cache.db`, outside purgeable caches. Copying fallback files never replaces downloaded cache entries. Download or parse failures retain the last valid rules; updates are independent per rule set.

The **Роутинги** tab saves **С роутингом** (the existing behavior, enabled by default) or **Без роутинга**. Without routing, only sniffing and DNS interception remain, `final` is still `vk-wg`, and no rule sets, direct exceptions or rejects are configured. DNS settings and the selected VPN transport are unchanged. The selection is persisted and the route snapshot for the extension is updated immediately; it applies to the next app or system VPN start without restarting the active tunnel.

DNS is a minimal new UDP resolver at `1.1.1.1`, IPv4 only, via native WG in combined mode and directly in baseline. It is not the source config's DNS. Both modes use the same routing and rule-set data.

The existing VK proxy library supplies only TURN/WRAP-A transport and provisioning. Its separate WireGuardBridge/device is not used. Both components run in one Go runtime inside the VPN extension. WireGuard uses one worker and MTU provisioned in the 1280–1500 range, with TUN MTU 1280. Existing proxy logging and credential cache remain confined to the isolated prototype container. User links are imported into its Keychain; the temporary app Documents seed is removed. The superclass's startup snapshot containing provisioned WG keys is removed after startup.

## Build and checks

The routing Swift tests run with `python3 -m unittest discover -s scripts/tests -v`.
The native cache integration test additionally uses `build/sing-box-check`; build
it from the pinned core to enable the test (otherwise that test is skipped):

```sh
mkdir -p build
(cd upstream/sing-box && go build -ldflags=-checklinkname=0 \
  -tags with_wireguard,with_gvisor,with_utls,with_clash_api,with_low_memory,badlinkname,tfogo_checklinkname0 \
  -o ../../build/sing-box-check ./cmd/sing-box)
```

The test uses a loopback HTTP proxy as the `vk-wg` transport, verifies a successful
binary rule-set update, then a corrupt update, and restarts without the initial
file to prove restoration from the last valid native cache. It creates no TUN
and changes no system routes. Real VPN downloads still require device testing.

Requirements: Xcode 27, Go (this run used 1.27.0), existing core and Runestone source checkouts, an Apple development signing account. The local replacement in core `go.mod` refers to `../../ThirdParty/VKTurnProxy`.

```sh
DEVICE_UDID=<your-device-udid> scripts/build_vk_turn_prototype.sh
# Optional: SOURCE_PACKAGES_DIR=<existing-Xcode-SourcePackages-directory>
cd upstream/sing-box
go test -race -ldflags=-checklinkname=0 -tags with_wireguard,with_gvisor,badlinkname,tfogo_checklinkname0 ./protocol/vkturn
cd ../../ThirdParty/VKTurnProxy
go test -race ./pkg/proxy -run 'TestSendPacketUntil|TestTheBufferIsRecycled|TestExactlyTwoPutSitesExist|TestSendPacketStampsTheEnqueueInstant'
```

`-checklinkname=0` and the related build tags are required by this existing core/toolchain combination. Gomobile/gobind are pinned at the project's `v0.1.12`.

The Mac probe `cmd/vk-turn-prototype-check` accepts a private input file, replaces TUN with loopback SOCKS, and does not install Mac system routes. A real run returned YouTube HTTP 204 through `endpoint/wireguard[vk-wg]` and captive.apple.com HTTP 200 through `outbound/direct[direct]`. The source Apple rule set contains `captive.apple.com`, but not `www.apple.com`.

## Device measurement

Enable **Базовый замер** for sing-box with no WG/TURN; disable it for native WG through TURN. The default is 30 requested TURN connections, matching the original app; one connection can be selected to measure minimum overhead. iOS VPN permission is required once for the new app. After changing the mode or count, stop and restart VPN; settings apply at the next start.

The extension records `TASK_VM_INFO.phys_footprint` once per second throughout the tunnel lifetime, including bootstrap and core startup. Live UI status updates every second; disconnected or more than five-second-old status displays no memory value. CSV records every second for the first 720 seconds, then at one-minute boundaries (780, 840, … seconds), plus a final stop/failure sample. No sample history is retained in RAM. This is the extension's actual Darwin memory footprint, not RSS, Go heap, an estimate, or combined app-plus-extension memory. The main app's UI memory is outside this figure.

CSV lives in the app group's `Library/Caches/Prototype`; **Подготовить CSV** copies the latest file to the app's Documents for export. Columns include elapsed time, phase, footprint bytes, requested and active TURN connections, and cumulative TURN tx/rx bytes. Baseline has zero active TURN connections. A failed bootstrap is not a usable measurement.

```sh
python3 scripts/analyze_vk_turn_memory.py capture.csv --warmup-seconds 120
python3 -m unittest discover -s scripts/tests -p 'test_vk_turn_*.py'
```

The analyzer excludes startup and the first 120 seconds from median/p95, retains the startup-inclusive peak separately, and rejects incomplete TURN pools. Compare captures on the same phone and network, with the same foreground workload and duration. A short idle sample cannot predict sustained video/download memory or establish jetsam headroom.

## Prototype limitations

No IPv6 configuration, no production subscription UI, and no long-run/reconnect soak test. TURN bind sends can wait at most one second for room in the queue; a timed-out UDP packet is dropped so WireGuard rebind/shutdown cannot wait forever. Legacy proxy `SendPacket` behavior is unchanged. Startup generations prevent a stopped asynchronous bootstrap from registering later.

## Crash diagnosed during device testing

Two 30-session runs ended after 29 and 85 seconds with SIGSEGV/Go panic, before a steady measurement. CSV peaks were 39.31 and 38.24 MiB; both had 30 active connections and received actual traffic. The private Go crash log identifies `oomprofile.writeHeapProto` line 324, called by `goMemoryPressureCallback` when iOS signaled critical memory pressure. This is a diagnostic crash, not evidence of an iOS jetsam kill; no corresponding new JetsamEvent was found.

The profiler declared the old private `runtime.pprof_memProfileInternal` record layout (four counters followed by a stack slice). Go 1.27 uses an ObjectSize counter and two object counters; the stack slice is at a different offset. Reading it through the old ABI produces an invalid pointer. A test generating actual profiles reproduced the same panic on the Mac.

The heap/allocs writer now uses supported `runtime.MemProfile` / `runtime.MemProfileRecord`, avoiding that private ABI. Public heap sample stacks are limited to 32 frames. All six report profile types passed the regression test under the race detector. Combined startup also writes and checks those profiles on the physical phone before marking the steady phase, with proof in `Library/Caches/Prototype/OOMVerification/verified.json`. System pressure monitoring remains enabled.

The baseline reference captured 337 seconds, with 120 seconds excluded: median 22.94 MiB, p95 23.10 MiB, peak 23.45 MiB. The failed 30-session runs are excluded from steady comparisons. Final combined results will be recorded after verification.


## Continuous memory display follow-up (2026-10-13)

The completed device CSV stopped after 720 samples (last elapsed time 719.004 s and 41.564 MiB); the UI kept displaying that last value. An independent subsequent Instruments snapshot read 38.127 MiB from the same extension PID, confirming the old display was not a live reading.

The sampler now keeps publishing timestamped physical footprint until tunnel shutdown. CSV keeps its second-by-second startup section, then records one sample per minute, plus a terminal stop/failure row. The UI suppresses disconnected or stale footprint without hiding an extension startup error. The file format and export action remain compatible with the existing analyzer; longer captures include fewer samples per minute after startup, so its median/p95 are sample-weighted, not time-weighted.

Ten script tests pass, including a native Swift harness running the production sampler/file I/O and refresh method against controlled clock and connection inputs. The original 12-minute cutoff and the disconnected-error regression were reproduced before their fixes. The signed iPhone build passed, and CoreDevice confirmed installation and launch on the iPhone 13. The disconnected state and updated explanatory text were inspected on its physical screen. The existing simulator UI smoke test also passed (one test, zero failures). The analyzer accepts long captures up to 86400 rows. A real continuous capture past the 12-minute boundary in this updated installed build is still pending.


## Manual VLESS mode (2026-10-13)

The prototype now has a **VK TURN / VLESS** mode picker. A disconnected selection
is saved without starting VPN; changing a connected mode stops the old tunnel,
waits up to 15 seconds for disconnection, and starts the chosen mode. Startup and
shutdown disable switching. Selecting the active mode does not restart it. The
existing baseline toggle still starts the direct-only measurement and disables
the mode picker. TURN session count is disabled in VLESS mode.

VLESS and VK TURN are imported at runtime from the existing subscription server.
Enter its HTTP(S) subscription URL and tap **Получить конфиги** while VPN is stopped.
The response contains only `sing_box_url` and `vk_turn_link`. The app downloads
JSON from `sing_box_url` and extracts VLESS connection parameters. The server
keeps JSON on the Mac and serves it at `/subscription/<token>/config`, protected
by the same token. No plan name, remaining days, schema version, or embedded
configuration is returned. Missing, null, empty, or invalid connection data
disables that mode. A successful update replaces both modes; network failures,
HTTP errors, and redirects from either URL retain the last saved subscription. Set the server's `SING_BOX_CONFIG_PATH` or
`VK_TURN_LINK` to an empty value to disable the corresponding mode.

Manual import supports a JSON file, pasted JSON, and a VK TURN link. The importer
keeps only the `R3-N1` VLESS outbound, or the single VLESS outbound if that tag is
absent. A raw VLESS outbound is also accepted. Ambiguous nodes, invalid required
fields, and nodes depending on another outbound through `detour` are rejected.
Imported `route`, DNS, inbounds, and other outbounds are discarded. The original
server JSON is not modified; a connection-only JSON is sufficient for this app.

Build with `DEVICE_UDID=<your-device-udid> scripts/build_vk_turn_prototype.sh`.
No subscription credentials are required or bundled during the build. The old
`vless-outbound.json` resource, preparation script, and Documents seed importer
have been removed. On the first launch of this version, legacy runtime VLESS
and Keychain credentials are cleared if no new import cache exists. New imports
are cached atomically with iOS file protection in the isolated App Group, and
only copied into the extension's runtime files/Keychain when starting VPN.

Application DNS uses VLESS; only the VLESS server hostname is resolved using a
separate direct bootstrap DNS server. TLS, REALITY, Vision and other supplied
node parameters are retained. VLESS startup does not read the VK TURN Keychain,
bootstrap VK, create a TURN session, or create a WireGuard endpoint.

VLESS captures have `vless-startup` / `vless` phases and zero requested/active
TURN sessions. The analyzer accepts those captures and rejects a VLESS capture
containing TURN sessions. Foreground app memory is still outside the extension
footprint. No new physical-device memory result is claimed by this change.

The existing `patches/sing-box-vk-turn-prototype.patch` includes the added VLESS
configuration and bootstrap tests, preserving the prototype's prior core and
OOM-profile fixes. Live VLESS/REALITY reachability remains a separate check from
configuration validation: the Mac probe reached the configured server by TCP,
but its routed YouTube request ended with EOF. No server parameter was guessed
or changed to hide that result.


Verification for manual VLESS mode:

- Signed iOS `VKTurnPrototype` build and both rebuilt Libbox slices passed; the
  signed app bundle contains the exact private resource prepared from the
  subscription JSON. Final build log: `/tmp/sing-prototype-vless-build-final.log`.
- Full `protocol/vkturn` and `experimental/libbox` tests passed under the race
  detector, including real DNS/outbound lifecycle startup and a loopback VLESS
  server forwarding an actual TCP payload with no TUN/system route changes.
  Log: `/tmp/sing-prototype-vless-core-transport-final.log`.
- 18 memory/native Swift tests and 2 private-resource preparation tests passed.
  Native restart tests cover waiting for disconnection, offline selection,
  repeated same-mode selection, switching during connection, and preserving
  running VLESS when the TURN link is missing.
- Both simulator UI smoke tests passed, including VLESS choice surviving app
  relaunch. Final log: `/tmp/sing-prototype-vless-ui-tests.log`. The rendered
  screen was inspected; evidence: ignored `build/vless-ui-evidence/mode-picker.png`.
- One independent read-only review reported no remaining actionable issue.
  Git whitespace checks and build-script syntax checks passed. SwiftFormat and
  SwiftLint are not installed, so those checks were not run.
- Installation on the physical iPhone was deferred: CoreDevice confirmed the
  currently running VPN extension belongs to the existing VK TURN Prototype.
  Its live VPN/memory capture was not interrupted. Physical mode switching,
  private-server connectivity, and VLESS memory measurements remain unverified.


## Simplified UI and active-mode logs (2026-10-13)

The main screen now keeps the manual VK TURN / VLESS choice, TURN link input,
VPN controls, current memory and report export. Baseline and TURN-count controls
and instructional text were removed. New connections use 30 TURN sessions.
Previously saved test settings are no longer loaded by the app.

The top-right Logs button opens the active mode's journal with search, pause
and copy. It subscribes only while visible and the app is foreground, through
the existing local CommandClient. The visible buffer is bounded to 1000 lines.
The integrated TURN transport's standard-library logs are delivered to the same
core command-server stream; up to 100 startup messages are replayed when the
server is ready. Starting a new mode clears that startup backlog. Known TURN
credentials and secret fields are redacted before delivery.

The signed build passed, as did 20 script/native Swift tests and full core
package race tests. CoreDevice confirmed installation and launch on the iPhone;
the user explicitly allowed interrupting its active VPN for this update.
Live traffic log viewing on the physical phone remains a manual check.

The prior private-server EOF was subsequently resolved by the user in Remna.
A standalone TCP/REALITY/VLESS HTTPS probe returned YouTube HTTP 204.

All three simulator UI tests passed, covering opening the correct mode's log
window and preserving VLESS selection across app relaunch. The persistence
assertion checks the log window's active-mode title rather than the unreliable
SwiftUI segmented button `isSelected` flag. Log: `/tmp/sing-prototype-logs-ui-final.log`.
The simplified main screen was visually inspected from a simulator screenshot.

## Subscription import verification

```sh
python3 -m unittest discover -s scripts/tests -v
# In a separate terminal, start the localhost fixture for UI tests:
python3 scripts/tests/test_prototype_subscription.py
# Then run XCTest:
xcodebuild test -scheme VKTurnPrototype -destination 'platform=iOS Simulator,id=<UDID>' -only-testing:SFIUITests/PrototypeSmokeTests
```

The Swift importer tests use synthetic credentials and exercise normalization,
optional modes, invalid data, cache encoding, HTTP download, and redirect rejection.
UI tests import synthetic data through the interface and clear it afterwards.
They verify disabled modes, persistence, logs for both modes, and invalid VK links.

## Mode selector and subscription URL

The mode selector uses the system segmented Picker. The selected segment is
visually highlighted, and selection persists across relaunch. Unavailable modes
are disabled; changing a connected mode uses the existing stop/wait/start flow.
The subscription URL is always a normal text field. The eye button controls
only the manual VK TURN input. UI checks cover selected segments, persistence,
and keeping the subscription URL readable when the eye button is toggled.

## Russia inside routing

The second routing segment is now **Russia inside**, replacing **Без роутинга**.
The legacy stored value `disabled` maps to the new mode, so the existing selection
survives an update. Only the official `russia_inside.srs` release asset from
itdoginfo/allow-domains is used: listed domains go to `vk-wg`, with `direct` as
the final outbound. The original RoscomVPN mode is unchanged. DNS sniffing and
hijacking remain enabled in both modes. Russia inside additionally enables DNS
reverse mapping so domain rules can match opaque TCP/UDP connections resolved
through the application DNS server, without changing its resolver or detour.

The bundled `RuleSets/russia-inside.srs` seeds the native daily updater and cache.
Routing changes validate and prepare resources before stopping a connected VPN,
wait up to 15 seconds for disconnection, then save the route and reconnect using
the selected transport. Offline selections do not start a VPN. Selecting the same
mode or changing modes while connecting/disconnecting does not restart the VPN.

The Swift harness in `scripts/tests/test_vk_turn_switching.py` exercises connected
and offline routing changes, transitions, unchanged selections, corrupt resources,
and stop timeout. `PrototypeSmokeTests/testRoutingChoicePersistsAndDoesNotStartVPN`
checks the new segment and persistence in the simulator. Physical-device tests
remain opt-in because they temporarily change the active VPN.

## Native Remnawave four-node failover (2026-10-20)

The compatible client sends `X-Subscription-Capabilities: vless-failover-v1`
on descriptor/config/UI requests. Config may be a typed provisioning document
(`kind=vless-failover`, schemaVersion 1), containing four personal nodes and a
priority policy. It is validated and cached atomically with the UI. HTTP 503,
invalid policy, cancellation and stale transactions retain the previous cache;
a successful restricted/unavailable document removes VLESS for the next start.
Legacy single-node JSON and VK TURN remain independent modes.

At start the app writes one immutable `prototype-vless.json`. The extension
creates four VLESS outbounds, one `vk-wg` selector with connection interruption,
and one existing TUN/core. DNS, routes and remote rule-set downloads still target
`vk-wg`; node hostname resolution uses direct bootstrap DNS. Policy is validated
against the final config and passed through Libbox's external override. All-down
never changes proxy routing to direct. Ordinary failover does not reload NEVPN.

The existing memory sampler also exports optional failover status in
`prototype-status.json`; UI considers it current for at most 5 s. There is no
second timer, history array, temporary probe core or periodic reserve warming.
The selector holds a healthy backup until three primary successes. The two
health URLs share a 5 s outbound deadline, with sequential candidates; all-down
startup can therefore take approximately 20 s plus initialization. Network
restrictions on both health URLs can produce false all-down.

For the cross-repository synthetic contract check, set `VPN_BACKEND_PYTHON` to
an existing backend Python 3.13 environment and put the existing Go toolchain in
PATH, then run the script suite. The test creates two synthetic users, changes a
group and revokes a key, passes backend responses through production Swift and
builds/validates them with production Go/Libbox; it uses no production keys.

```sh
VPN_BACKEND_PYTHON=/path/to/backend/python python3 -m unittest discover -s scripts/tests -v
python3 scripts/tests/prototype_ui_fixture.py
# In another terminal:
xcodebuild test -project sing-box.xcodeproj -scheme VKTurnPrototype \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -only-testing:SFIUITests/PrototypeSmokeTests \
  -only-testing:SFIUITests/PrototypeDeviceRoutingTests
```

The device routing test intentionally skips on simulator. Device networking and
memory acceptance remain separate: see [remnawave-failover-memory.md](remnawave-failover-memory.md).
No production deployment or feature enablement is part of this local change.
