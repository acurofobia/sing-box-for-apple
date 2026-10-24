# Third-party notices

WhiteLink is an independent derivative. It is not the official sing-box Android application.

SagerNet/sing-box and SagerNet/sing-box-for-android are copyright their respective authors and contributors, distributed under GPL-3.0-or-later. Vendored source retains copyright, license files and individual notices. Android integration is derived from VPNService, BoxService, PlatformInterfaceWrapper and DefaultNetworkMonitor in SFA.

The TURN package is vendored from the local iOS project's ThirdParty/VKTurnProxy, module github.com/cacggghp/vk-turn-proxy, originally anton48/vk-turn-proxy-ios. Its repository license is GPL-3.0-or-later; individual MIT and other SPDX notices are retained (including WRAP-A and GETCONF implementation). Full source, go.mod and go.sum accompany the test APK.

Go dependencies are resolved in the single sing-box module graph. Their exact versions and hashes are retained in vendor/sing-box/go.mod and go.sum and vendor/vk-turn-proxy/go.mod and go.sum. These include Pion TURN/DTLS/transport, bogdanfinn fhttp/tls-client, gVisor, WireGuard and the SagerNet networking libraries. Original licenses in upstream modules remain applicable.

Android dependencies include Kotlin, AndroidX Compose/Activity/Lifecycle/Core, and kotlinx.coroutines. Versions are fixed in the Gradle build; their original Apache-2.0 and other licenses remain applicable.

The 21 local .srs files and routing.json are copied from the provided PrototypeApp. Their SHA-256 hashes are recorded in the build manifest. They are not downloaded or refreshed by this test client.

The complete GPL license text is in LICENSE, alongside the original vendored license files. The source bundle contains the complete modified application and native integration sources required to rebuild this version, plus Gradle scripts and the fixed source snapshots.
