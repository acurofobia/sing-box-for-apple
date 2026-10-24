# Local source release

This workflow prepares source material locally. It does not commit, push, upload, or publish. It does not establish that the existing `Libbox.xcframework` was built from this source, settle TestFlight/GPL compatibility, or clear dataset/image rights. Rebuild the core and application from the frozen source before distributing a release candidate, and retain hashes of those binaries alongside its source manifest.

## Prepare and inspect

Requirements: Python 3.10+, Git, Go 1.26.10 (the checked core requires Go 1.26), Xcode 27.1/iOS 27.1 SDK for rebuilding the currently configured iOS 27 application. The existing prototype build script pins gomobile/gobind to v0.1.12. The macOS host used for dependency selection is arm64. Apple SDKs and compiler binaries are separately obtained system toolchains; they are not redistributed here. Swift source/runtime licensing remains applicable to the separately supplied Apple toolchain. Go runtime and standard-library sources, LICENSE and PATENTS are included in the source bundle.

Initialize the three top-level submodules at the recorded revisions using the repository's normal setup. Do not recursively initialize `upstream/sing-box/clients/*`: these platform clients are unrelated to this prototype build. Resolve Swift packages with Xcode and populate the Go cache using the existing build workflow before invoking the exporter. The exporter runs Go with `GOTOOLCHAIN=local`, `GOPROXY=off`, `GOSUMDB=off`, `GOWORK=off` and readonly module mode. It cannot silently fetch a dependency or choose a newer toolchain.

```sh
python3 -m unittest discover -s scripts/tests -p test_release_sources.py -v
python3 scripts/prepare_release_sources.py --check
python3 scripts/prepare_release_sources.py
# For a different already-resolved Xcode cache:
python3 scripts/prepare_release_sources.py --swift-checkouts /absolute/path/SourcePackages/checkouts
```

The output is `build/release/vipin-source.tar.gz`, plus `.sha256` and `.manifest.json` siblings. No timestamp enters archive metadata; identical source bytes, executable modes, revisions and dirty states produce identical gzip bytes. The manifest lists SHA-256 and size for every payload file; its own bytes are covered by the external archive hash. It records source revisions and tracked dirty state separately for the app, core and required submodules. Untracked files are included only through the explicit `REQUIRED` file list in the script. Review that list whenever release files are added. The additional upstream notice inputs use `scripts/license_sources/manifest.json`: the exporter includes this manifest and exactly its referenced font/package notice files after checking safe relative paths and SHA-256. Missing files, symlinks, ignored paths and hash mismatches abort export. Other files in that directory are excluded even when tracked. Generic inclusion of all untracked files is intentionally unsupported.

The exporter reads current tracked working files, including modifications, and rejects missing selected files, merge conflicts, unreviewed symlinks and uninitialized required submodules. Relative symlinks are preserved only when they resolve inside the same source repository to an included file or directory; manifest SHA-256 for a symlink covers its link-target text. It excludes Git metadata, ignored untracked files, output/build trees, downloaded design references, `.env*`, keys and known private test configuration. This is a conservative path policy, not a secret-content scanner: review tracked source changes before sharing. Avoid changing source during export; payload files are hashed before and after writing, and export aborts on detected changes. Archive creation is atomic, but callers must treat any failed invocation as failure regardless of a prior archive's presence.

## Included dependency source

The Go selection is recalculated for the actual prototype tags in `scripts/build_vk_turn_prototype.sh`, for iOS arm64 and amd64, plus the host gomobile/gobind packages. Full selected module trees are preserved under `dependencies/go/modules`, including applicable license and notice files. Available module metadata for the graph and cached zip/checksum material (plus version info when cached) for source modules are included under `dependencies/go/cache/download`. Local replacements are accepted only for the included core and `ThirdParty/VKTurnProxy`; an unexpected external local replacement aborts. The original relative replacement in `upstream/sing-box/go.mod` remains valid after extraction because directory layout is preserved.

The five Swift packages linked by the prototype's Library target are included at clean revisions matching `Package.resolved`: BinaryCodable, LegacyBinaryCodable, GRDB.swift, DeviceKit and PLCrashReporter. Their manifests and license materials accompany their source in `dependencies/swift`. Other pinned products serving unrelated application targets are not included. The Xcode project still declares these other packages: a fresh Xcode resolution may contact their upstream repositories even though this iOS product does not link them. This bundle is not an offline SwiftPM cache, and no claim of an entirely offline Xcode rebuild is made. The selected packages' source is available locally for review, modification and Xcode local package overrides; their upstream URLs/revisions remain recorded in both lockfile and source manifest.

The source manifest and `docs/testing/testflight-go-dependencies-2026-10-22.json` document dependency selection, not a verified SBOM of an existing IPA. Generated legal resources and the release license inventory accompany the app source. Full module source trees retain nested notices; inclusion does not resolve missing or unclear upstream license grants. In particular, fhttp, rule datasets and branding still require the review described in the readiness report.

## Extract and rebuild

Verify the external archive checksum first, extract into a new directory and inspect `SOURCE-MANIFEST.json`. Do not overlay a developer's private working tree.

```sh
shasum -a 256 -c vipin-source.tar.gz.sha256
tar -xzf vipin-source.tar.gz
cd vipin-source
# Use an isolated Go cache restored from the supplied dependencies:
mkdir -p build/source-gopath/pkg/mod
cp -R dependencies/go/cache build/source-gopath/pkg/mod/
cp -R dependencies/go/modules/. build/source-gopath/pkg/mod/
export GOPATH="$PWD/build/source-gopath"
export GOMODCACHE="$GOPATH/pkg/mod"
export GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOWORK=off
mkdir -p build/go-tools
(cd upstream/sing-box && GOBIN="$OLDPWD/build/go-tools" go install github.com/sagernet/gomobile/cmd/gomobile github.com/sagernet/gomobile/cmd/gobind)
```

Use `scripts/build_vk_turn_prototype.sh` for the recorded prototype tags and linker settings. It places the rebuilt framework at `upstream/sing-box/Libbox.xcframework`; the Xcode project references this same path, so no framework relocation is required. Resolve Swift packages using Xcode, or configure local package overrides pointing at `dependencies/swift/<identity>` for the included five packages; preserve their recorded versions. The script's `SOURCE_PACKAGES_DIR` option supports an already resolved normal Xcode cache, not the plain archived source directories.

For a Release build after the core rebuild, run the equivalent unsigned validation command (adjust signing only for your own team and device):

```sh
xcodebuild build -project sing-box.xcodeproj -scheme VKTurnPrototype \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO DISABLE_SWIFTLINT=1
```

The project build script first attempts a Debug Xcode build, so when preparing only the core follow its `gomobile bind` invocation directly, then run the desired Xcode command. A new unsigned build proves compilation only. Record the exact toolchain, complete command/environment, selected source manifest hash and newly produced framework/app hashes before claiming binary correspondence. Source export alone does not verify signing, device networking, runtime privacy, license compatibility, or approval by Apple.
