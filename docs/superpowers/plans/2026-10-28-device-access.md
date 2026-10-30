# Device access implementation plan

**Goal:** Add stable iOS HWID and remove WDTT credentials and stop its tunnel when the subscription server revokes this device; deliver the server integration contract without changing servers.

**Architecture:** Generate stable device identity and receive access decisions only in the ordinary subscription manifest. Persist versioned decisions separately from full provisioning so a failed VLESS/UI download cannot undo a revocation. No standalone endpoint, periodic polling or network checks before connection.

**Spec:** Approved requirements in this chat, including a two-device server default, separate WDTT/VLESS decisions and explicit revocation received on ordinary subscription refresh.

**Constraints:** Preserve current uncommitted changes. Work in this checkout because its current changes are part of the app being extended. No commits, deployments, backend changes, dependencies or production calls. Use existing Swift/Python harnesses and iOS UI tests.

## Review focus

- Late responses from another subscription or older revisions must not restore access or clear a different subscription's runtime.
- A denied response must remove cached/runtime WDTT credentials even if subsequent VLESS/UI loading fails.
- Network errors and malformed responses must not become revocations; persisted revocation survives them.
- Revocation is received only during subscription refresh; no extra access requests may be made by the app or extension.
- Native HWID/token headers must not leak to a different origin or redirects.

## Tasks

1. [x] Add failing behavioral tests for identity headers, versioned access decisions, cache redaction, independent failure handling and HTTP origin rules. Run and confirm expected failures.
2. [x] Implement device identity, manifest access decisions and locked persistence; wire the subscription loader/store and app revocation handling. Run the targeted tests.
3. [x] Apply received revocation in the app, stop WDTT and add UI coverage. Build the prototype and run available simulator checks. Removed standalone checks per the user’s subsequent simplification request.
4. [x] Document exact request/response examples, backend registry/revocation/concurrency rules, Remnawave forwarding, WDTT migration constraints and acceptance tests. Run regression checks and review the final diff.

## Verification and review

- Python regression suite after simplification: 113 tests, OK, 1 cross-repository contract fixture skipped because VPN_BACKEND_PYTHON was not set.
- iOS simulator build of app and extension passed. XCTest passed the new revocation/HWID/relaunch test; the existing full-reset UI test also passed.
- SwiftLint on changed Swift sources: no violations. SwiftFormat is not installed in this environment; formatting followed nearby sources.
- Preserved per-source tombstones across subscription switches, atomic runtime key ownership checks and early revocation before unrelated manifest validation. Removed the extra asynchronous access-check path and its generation guards.
- No commits, backend edits, production changes or physical-device VPN tests.

## Simplification requested by the user

Removed the separate access endpoint/client, polling task, preconnect network checks and their supporting context/generation state. Decisions remain part of ordinary subscription downloads; cached WDTT access can continue until a refresh delivers revocation. Backend contract and privacy text now describe this behavior.
