# Instructions for the Android implementation handoff

This package is the reference for recreating the existing Sing VPN interface on Android.
Read README.md, docs/BEHAVIOR.md, docs/ANDROID.md and docs/ACCEPTANCE.md before implementing.
Inspect design/spec/screens.json, design/spec/tokens.json and the matching resolved layout JSON.
Open the corresponding PNG and iOS application screenshot before working on each screen.

- Preserve the accent color, artwork, spacing, card geometry, labels and state-dependent behavior.
- Use the existing Android project's stack and conventions. This package does not mandate versions.
- Implement semantic native UI components; full-screen reference images are not production UI.
- Keep content driven by the subscription UI document. Fixture values are not production constants.
- Auto mode is currently disabled even when the server fixture calls it available.
- Keep routing mode separate from connection mode. Russia inside is stored as "disabled" in iOS
  for compatibility; it does not mean VPN is disabled.
- Adapt Android system insets, VPN permission, back navigation, keyboard and accessibility.
  Do not hardcode the iPhone status bar inset or screenshot resolution as Android pixels.
- Do not add the archived onboarding help dialog as a functional feature.
- The Swift reference is not a complete buildable project. It is authoritative for existing behavior.
- Mock fixtures demonstrate data and UI, not a working connection to example.org.
- After each meaningful screen change, run the available Android checks and verify emulator screenshots.
  Report what was and was not tested. Do not claim a real VPN connection based on fixture UI state.
- Preserve this handoff directory and record intentional platform differences in the Android project.

If this package is nested below another repository, its AGENTS.md applies to this subtree.
The repository's root AGENTS.md should explicitly reference this guide for Android source work.
