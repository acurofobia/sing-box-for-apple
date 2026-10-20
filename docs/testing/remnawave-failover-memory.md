# Remnawave VLESS failover: memory acceptance

Status on 2026-10-20: **not measured; hardware acceptance is incomplete**.

A physical iPhone 13 (iPhone14,5), iOS 27.0.1 (24A446), was detected through
CoreDevice. Libbox was rebuilt with Go 1.26.0 and the signed VKTurnPrototype
Debug build succeeded. This run did not install synthetic provisioning over the
phone's saved personal subscription or connect production accounts for a test.
There is no isolated Remnawave test instance; the user confirmed that its
SRR/HWID generated-response acceptance must remain incomplete. The local
synthetic HTTP/Swift/Go roundtrip is not evidence of a physical VPN connection.

| Scenario | Median / p95 | Startup-inclusive peak | Delta vs one VLESS | Settled after transitions |
|---|---|---|---|---|
| One VLESS, same build/routing/workload | Not measured | Not measured | Reference pending | Not measured |
| Four VLESS + priority failover | Not measured | Not measured | Not measured | Not measured |
| Healthy backup | Not measured | Not measured | Not measured | Not measured |
| All-down | Not measured | Not measured | Not measured | Not measured |
| At least 20 failure/recovery transitions + 5 min | Not measured | Not measured | Not measured | Not measured |
| Screen locked / Wi-Fi↔cellular | Not measured | Not measured | Not measured | Not measured |

No MB overhead, iOS memory limit, absence of leaks or traffic safety claim is
made. Old VK TURN/baseline captures in vk-turn-prototype.md are not a one-VLESS
reference for this feature. Host race tests and simulator UI tests cannot
substitute for these measurements. Mass enablement remains gated.

## Reproduction protocol

1. Obtain a generated synthetic `/api/sub/{shortUuid}/json` from an isolated
   Remnawave 2.6.4 instance. Verify SRR, injectHosts, external squad and HWID
   behavior without registering devices for production users.
2. Provision four reachable RAW/REALITY nodes in a controlled test network.
   Compare a legacy single node against the four-node document on the same
   iPhone, build, network, routing rules and repeatable video/download workload.
   Repeat at least two pairs, each with 120 s warm-up + 600 s measurement.
3. Record the existing extension `TASK_VM_INFO.phys_footprint` CSV on disk.
   Retain startup samples. Identify each capture externally as single/failover
   (both use phase `vless`; do not infer the arm from a filename alone).
4. Repeat on a working backup and all-down. Cause actual test-server network
   failures separately from simulated probe results. Exercise at least 20
   transitions, then observe for 5 min; include idle, active traffic, screen lock,
   foreground app termination, and Wi-Fi/cellular changes. Verify DNS, TCP and
   UDP/QUIC in both routing settings. HEAD 204 only proves the HTTP probe.
5. Analyze equal 120–720 s windows. For longer/nonuniform captures use the
   analyzer's `time_weighted` median/p95 (previous sample held until the next
   timestamp); the legacy `median`/`p95` fields explicitly remain
   `aggregation=sample-weighted`. A final isolated sample has no known duration.
   Report coverage and sampling gaps; the model cannot recover unsampled peaks.
6. Report per-arm median, p95, startup-inclusive peak, paired delta and natural
   between-run variation. Check one client core/controller, at most one probe,
   bounded goroutines/connections and settled footprint after transitions with
   allowance for Go GC. No sustained accumulation, crash/OOM/restart or proxy
   leakage to direct is acceptable. A peak near observed memory pressure or
   unconfirmed overhead blocks enablement pending investigation and repeats.

```sh
python3 scripts/analyze_vk_turn_memory.py /private/path/capture.csv --warmup-seconds 120
```

Local verification covers graph ordering/ambiguity, atomic snapshots, cached
cold start before remote rule sets, sequential probes, failure/recovery
thresholds, cancellation and all-down without direct fallback. It does not
complete any of the physical measurement rows above.
