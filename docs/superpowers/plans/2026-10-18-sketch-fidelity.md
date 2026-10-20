# Sketch fidelity implementation plan

> Execute sequentially in this session. User requested implementation and visual verification; no commits.

**Goal:** Match every screen/state on the Sketch “Превью / VPN” page in the native iOS prototype.
**Architecture:** Restyle the existing SwiftUI views and reuse the existing model, subscription contract and presentation coordinator. Export source artwork from Sketch. Retain TabView selection and NavigationStack; reproduce the visible tab panel with native SwiftUI buttons at the source dimensions. Hide the status bar to match the source full-screen composition.
**Tech Stack:** SwiftUI, XCTest, existing Python fixture, Sketch exports.
**Spec:** output/design/sing-vpn-interface.sketch, page “Превью / VPN”; this user's explicit instruction supersedes earlier visual compromises.

## Constraints
- Preserve VPN lifecycle, transport selection, routing and subscription contracts; no changes to real credentials, signing, external services or the Sketch document. The source ping button invokes the existing local core URL test only when a real outbound is available.
- Preserve all existing uncommitted work. No new dependencies.
- Use real runtime metrics; never populate production metrics with sample values.
- Check source and simulator at the same viewport and state, saving paired images.

## Tasks
- [x] Export and inspect all 11 reference screens and component styles/assets.
- [x] Capture current baseline; extend screenshot UI verification for empty/filled onboarding, disabled help, both VPN states at both heights, modes/restricted modes, profile/account dialog.
- [x] Restyle onboarding, subscription card, progress, profile/dialog, mode drawer and VPN card using measured source values; retain interaction/accessibility identifiers.
- [x] Build and capture all states on 390×844 simulator; compare pairs, fix discrepancies and repeat.
- [x] Run existing targeted functional tests, format/lint changed Swift files, inspect adaptive layout and record visual verification and limitations.

## Review focus
- Missing/hidden server blocks remain safe; long text and Dynamic Type remain usable.
- Open mode drawer blocks background interaction; close/details/restricted action still work.
- Card expansion retains its bottom anchor; all metrics stay honest.
- Onboarding errors retain input; replacement cancellation keeps subscription.
- All 10 reachable source states receive paired captures; state 00б is unreachable because the user explicitly disabled its entry point. Live data and rasterization differences are recorded.

## Verification results

Final.xcresult: 11/11 UI tests passed. Python checks: 32/32 passed. SwiftFormat, SwiftLint and git diff --check passed. All 10 reachable Sketch states were screenshot-compared at 390×844; full-view pairs, overlays and focused comparisons are in build/sketch-fidelity/comparison/final/. See design-qa.md for exact evidence and limitations.

Independent review: all three P2 findings fixed; landscape expansion and full-width Cancel were reproduced RED before changes, then passed GREEN with bounded dialog scrolling. Native log/settings back navigation and drawer scrim closing were checked as well. No commits or publication.
