# vipin — TestFlight submission

The owner has accepted the earlier licensing, account-model, and reused-material decisions and instructed work to continue without contacting upstream authors. This document tracks the remaining publishing and submission work.

## Release identity

- App Store name and device display name: **vipin**.
- Version/build: **1.14.6 (2)** for both the app and packet tunnel extension.
- App ID: `ru.acurofobia.singbox.vkprototype`.
- Extension: `ru.acurofobia.singbox.vkprototype.extension`.
- Team: `YG7A3W5844`; App Group: `group.ru.acurofobia.singbox.vkprototype`.
- Contact: Sergey Mikhailov, `fusedased@gmail.com`.
- Privacy/support URL: <https://vipin.eagerdell32.chatgpt.site/>.
- Matching source release: <https://github.com/acurofobia/sing-box-for-apple/releases/tag/vipin-1.14.6-2>.

The app icon is the pinned Lucide shield-check icon. Its SVG, upstream license, revision, and reproducible renderer are in `docs/release/branding`. Notices are included in the app's license screen.

## Archive and export

The server-health fix from 2026-10-24 is present in the current sources and the
Release app built under `build/DerivedDataHealthDevice`. That development-signed
app was installed on the local iPhone. The existing
`build/vipin-1.14.6-2.xcarchive` and `build/release/vipin-app-store/sing-box.ipa`
were produced on 2026-10-22 and predate this fix. Regenerate the archive, App Store
export, and matching source/provenance artifacts before distributing this change
through TestFlight. A GitHub source push does not update an existing IPA.

```sh
xcodebuild archive -project sing-box.xcodeproj -scheme VKTurnPrototype \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/vipin-1.14.6-2.xcarchive \
  -derivedDataPath build/DerivedDataReleasePreparation \
  -clonedSourcePackagesDirPath build/DerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackagePluginValidation \
  -allowProvisioningUpdates DISABLE_SWIFTLINT=1

xcodebuild -exportArchive -archivePath build/vipin-1.14.6-2.xcarchive \
  -exportPath build/release/vipin-app-store \
  -exportOptionsPlist docs/release/export-options.plist -allowProvisioningUpdates
```

Export uses `app-store-connect` and allows external TestFlight testing. It does not set the internal-testing-only option. The archive may use an Apple Development identity; export performs distribution signing through the configured Apple account. For an upload through Xcode Organizer, open the archive, choose Distribute App, App Store Connect, and Upload.

## App Store Connect fields

Copy the description, feedback email, review contact, review notes, and What to Test text from `testflight-metadata.json`. Create/select the app using the existing Bundle ID and name **vipin**. Keep private test credentials in App Store Connect review notes rather than the public repository, policy page, or public release assets. A reviewer must receive a working test subscription that demonstrates the declared connection modes; subscription import instructions alone do not demonstrate a working tunnel.

Use the technical encryption inventory in the JSON when completing export compliance: the app includes encryption implemented outside Apple's OS and is not limited to ordinary HTTPS requests. The inventory does not automatically claim an exemption or assign an ECCN. Supply the documentation requested by the questionnaire for the selected territories.

After upload processing, select the build in TestFlight, complete any Missing Compliance requests, add an external tester group, enter review contact and test information, and submit the first external build to Beta App Review. Enable the public invitation after approval.

## Device verification

The existing `PrototypeDeviceRoutingTests` exercises saved real-device configurations, both available transports, both routing choices, HTTPS traffic, native rule-set downloads, and restoring the original routing/mode/connection state. It requires the explicit `PROTOTYPE_DEVICE_ROUTING_CHECK=1` opt-in and does not import or publish credentials. A local run with this opt-in is authorized as part of this release preparation. Manual Wi-Fi/cellular switching and an initial system VPN permission prompt still require interaction with the phone when encountered.

The test now accepts the app's first-connection privacy disclosure before starting the tunnel.
