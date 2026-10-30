# Drawer, routing and profile implementation plan

**Goal:** Apply the open Sketch design to the existing iOS client and implement hourly subscription refresh and application reset.

**Architecture:** Keep the existing SwiftUI views, provisioning store and priority failover controller. Extend the existing status snapshot with ordered server health, without changing failover selection or probe cadence. Quota comes from subscription block06, not session counters.

**Constraints:** Preserve all existing uncommitted changes. No commits, publishing, new dependencies, or changes to remote services.

- [x] Add behavioral tests for hourly throttling (including failures/relaunch/manual refresh), reset cancellation, quota formatting and ordered failover health.
- [x] Add ordered health snapshots to the Go controller and Swift status model. Preserve unknown states and invalidate obsolete results.
- [x] Move quota into the compact VPN drawer; add detailed server rows, memory and routing. Remove the separate traffic card.
- [x] Match routing rows to Sketch; retain saved values and reconnect behavior.
- [x] Separate legal actions in profile, audit repository references against configured remotes, and add confirmed full local reset that stops VPN before deleting configuration, credentials, settings and diagnostics.
- [x] Run targeted behavior tests, the existing Python suite, Go failover tests, iOS build and simulator UI tests; inspect screenshots against Sketch. Report any checks unavailable in this environment.

Review fixes: server health expires after two probe intervals plus the timeout; reset also removes temporary diagnostic exports; canceled and superseded diagnostic callbacks cannot recreate pre-reset logs. All have behavioral regression coverage. Selected servers with unknown health display “Проверка…”.

Verification: Python suite 111 tests, 1 skipped (external backend contract environment absent); Go priority failover tests with race detection passed; Libbox rebuilt for iOS and simulator; signed iOS device and simulator builds passed. Five final simulator UI scenarios passed, plus routing persistence/native-tab checks and the final reset interaction-lock test. Screenshots in `build/drawer-evidence/` were inspected against the open Sketch document. SwiftLint reports no errors and one pre-existing diagnostic Data/String warning; SwiftFormat is not installed. Real VPN failover was not exercised on a physical device.
