# Subscription UI Integration Implementation Plan

> Execute sequentially with superpowers:executing-plans. No commits or publication.

**Goal:** Integrate the approved subscription UI design with one-link provisioning.
**Spec:** ../specs/2026-10-18-subscription-ui-integration-design.md
**Architecture:** Keep PrototypeModel responsible for VPN lifecycle. Decode and validate UI independently; persist complete snapshots atomically; coordinate presentations centrally.
**Stack:** SwiftUI, Foundation, NetworkExtension, existing CommandClient, Python stdlib.

## Constraints

SFI / VKTurnPrototype only; iOS 27.0 unchanged. No dependencies, automatic transport selection, new measurements, signing changes, edits to real credentials, or Sketch modifications.

## Tasks

- [x] 1. Extend VPN server response, examples, validation, tests, and both servers' documentation.
- [x] 2. Implement typed UI document, strict JSON validation, ID bindings, and Swift/Python tests.
- [x] 3. Implement bounded downloads, authorization isolation, atomic complete cache, cancellation and generation handling.
- [x] 4. Separate subscription refresh from VPN operations; retain active runtime and selection; cover migration and switching.
- [x] 5. Implement onboarding, connection/profile tabs, native presentations/actions, metrics, localization, UI tests.
- [x] 6. Implement top drawer, upward VPN card expansion, accessibility and adaptive layout.
- [x] 7. Run targeted and regression tests, simulator build and UI verification, format/lint changed sources, final review.

## Review focus

- Old/partial cache never authorizes a new VPN start; running VPN can always be stopped.
- Refresh cannot change runtime credentials or automatically select another transport.
- Cancelled or replaced requests cannot commit late responses.
- Duplicate escaped keys and invalid hidden items reject the complete document.
- Modal sequencing survives live data changes and repeated gestures.

## Verification

Run server unittest suites; scripts/tests/test_prototype_*.py and test_vk_turn_switching.py; VKTurnPrototype simulator build and XCTest smoke tests. Check real network only on an explicitly enabled physical-device test. Capture before/after screenshots and verify animations interactively.

### Results — 2026-10-18

94 Swift/Python checks passed:

```sh
python3 -m unittest discover -s subscription-server/tests -v # 11
python3 -m unittest discover -s scripts/tests -p 'test_prototype_*.py' -v # 32
python3 -m unittest discover -s scripts/tests -p 'test_vk_turn_switching.py' -v # 18
# From /Users/acurofobia/code/subscription-ui-server:
python3 -m unittest discover -s tests -v # 33
```

`build/SubscriptionUIComplete.xcresult`: VKTurnPrototype built on iOS 27 Simulator;
all eight smoke tests passed, the physical-device routing test was skipped as intended.
The profile passed the XCTest hit-region accessibility audit. Tests cover genuine HTTP
loading, cache restoration, failures, foreground refresh, live restrictions, routing,
native sheets/dialogs, drawer gestures and bottom-anchored VPN-card expansion.
Connected screenshots use the DEBUG simulator-only connection state; metrics remain
unavailable rather than fabricated.

`build/SubscriptionUIiPadFinal.xcresult`: long content/landscape and hidden-menu/empty-mode
tests passed on iPad mini with the largest accessibility text size and the simulator's
actual Reduce Motion setting enabled.

Final geometry regressions passed in `build/SubscriptionUIPhoneFinal.xcresult`
(two tests) and `build/SubscriptionUIPadFinal.xcresult` (one test): no duplicated
top safe-area inset, bottom anchor retained during expansion, adaptive drag distance,
landscape scrolling and modal accessibility-container discovery. Tests explicitly
wait for portrait at launch and for spring expansion before measuring geometry.
The final screenshot helper captures the entire display, avoiding application-only
cropping of rotated scenes in XCTest.
`build/SubscriptionUILayoutEvidence.xcresult` passed on both iPhone and iPad with
that helper; portrait and landscape screenshots were visually inspected. The iPad's
text-size and Reduce Motion preferences were restored afterward.

Evidence is saved in `build/subscription-ui-evidence/`: `before.png`, states `00`,
`00a`, `01`–`07` including `03a`, and adaptive iPhone/iPad captures. These files are
local build artifacts; no screenshots or result bundles were added to Git.

SwiftFormat 0.64.0 and SwiftLint 0.65.1 passed for the twelve changed Swift files.
`git diff --check` passed. Independent review findings were corrected and covered by
regressions: explicit disconnect invalidates pending restarts, initial empty selection
cannot become an automatic selection after refresh, invalid calendar/timezone values
are rejected, and the drawer header remains pinned and supports interactive opening.

### Reproduction and deployment

Start `python3 scripts/tests/prototype_ui_fixture.py` before running
`SFIUITests/PrototypeSmokeTests` through the VKTurnPrototype scheme. The fixture serves
synthetic data at localhost:18081. Tests use a separate cache and preferences suite.
The physical routing test remains opt-in through `PROTOTYPE_DEVICE_ROUTING_CHECK`.

For real subscriptions, configure `UI_DOCUMENT_URL` and `UI_DOCUMENT_TOKEN` in the
VPN server's local environment as described in `subscription-server/README.md` and
run both servers. Existing real `.env` files were not modified.

### Remaining manual acceptance

No physical iPhone was connected, so real tunnel traffic and device routing were not
verified. Manual VoiceOver navigation remains to be checked on a device; modal focus,
escape actions, labels and touch targets are implemented, with automated hit-region
verification. These limitations do not imply that simulator connection states exercise
a real VPN tunnel.
