# Pi Voice

Pi Voice is a native voice interface for existing Pi sessions. It keeps each Pi agent’s model, context, tools, and inter-agent messaging intact while adding macOS and iPhone voice clients.

Pi Voice is a human endpoint, not a coordinator or a second agent. The user selects one exact live Pi session. Incoming messages never change that target automatically.

The gateway and native clients are distributed as source. Building or installing them is an explicit operator action; cloning this repository does not alter an existing Pi, gateway, or native app installation.

## How it works

- A local gateway observes the current Pi roster through `pi-intercom`.
- Each voice generation receives a unique, never-reused human endpoint.
- The client sends and receives audio directly over WebRTC with the supported GPT Live provider.
- The gateway holds the server-side provider credential and owns the trusted sideband connection.
- GPT Live decides **when** a request needs Pi work; the gateway decides **whether and where** that request may be delivered.
- Delivery is pinned to the selected broker session ID and endpoint epoch. Unknown delivery outcomes are not retried automatically.
- Pi replies return through the same generation-scoped endpoint and can be spoken by the active voice session.

The native clients do not run Pi locally, scrape terminal transcripts, inject terminal keys, or control the user’s other device. Agent-side tools continue to run wherever the selected Pi session runs.

## Clients

### macOS

`native/mac` is a SwiftUI menu-bar client. It includes:

- exact roster selection;
- Continuous and Push to Talk input;
- an optional global Right Option hold when Accessibility access is already granted;
- Keychain storage for the opaque per-device credential;
- WebRTC audio through `livekit/webrtc-xcframework` `150.7871.03`;
- a fake transport and deterministic policy checks.

The app does not request Accessibility access automatically. A real microphone, audio-route, permission, signing, or installation check requires an attended Mac test. Building the source does not replace an installed app or change its bundle identity, Keychain namespace, signing, or TCC permissions.

### iPhone

`native/phone` contains an iOS 17 SwiftUI app, policy core, CallKit integration, and Live Activity support. The real transport resolves `stasel/WebRTC` `154.0.0` at revision `0c0ad84dac6c1941c16a414dfcfba94691866e4c`.

The platform-neutral core builds with Swift Package Manager. The full app requires Xcode with the iOS SDK, an Apple development team, a provisioning profile, and a physical-device or simulator build. CallKit, Live Activities, background audio, lock-screen behavior, microphone routing, power-button ending, and real playback must be verified on a signed physical-device build; source checks alone do not establish those behaviors. Pi Voice does not claim Siri integration or a guaranteed two-hour call.

## Gateway setup

Requirements:

- Node.js 22.19 or newer;
- an OpenAI API key with access to the configured GPT Live model;
- a reachable Pi broker and the supported `pi-intercom` native client API;
- an exact client origin.

```bash
git clone https://github.com/Strand-AI/pi-voice.git
cd pi-voice
npm install
npm test

OPENAI_API_KEY='<server-side-key>' \
COMPANION_PUBLIC_ORIGIN='https://<private-hostname>' \
npm start
```

The gateway binds to `127.0.0.1`. Remote clients should use a private HTTPS origin, such as Tailscale Serve, that forwards only to the loopback gateway. Do not enable a public Funnel or broad network listener.

`COMPANION_PUBLIC_ORIGIN` is an exact security boundary. Scheme, host, and port must match during pairing, renewal, HTTP requests, and WebSocket setup. The gateway also enforces an explicit Host/Origin allowlist.

### Pair and manage devices

Run these commands on the gateway machine:

```bash
node dist/src/cli.js --pair
node dist/src/cli.js --devices
node dist/src/cli.js --revoke '<exact-device-id>'
```

Pairing creates a one-use, five-minute token. The command prints the exact gateway origin, raw one-use code, and an optional setup page that only displays those values; the page does not redeem the code. Enter the origin and code in a native client. The client stores only the returned opaque device credential in the platform Keychain and keeps its short session cookie in memory. The gateway stores only a credential hash and bounded device metadata in its private runtime directory.

A device expires after 90 days without renewal or 365 days absolutely. Revocation applies to one exact device. Pairing and renewal never start microphone capture or a paid provider session.

## Session limits and billing

A paid provider session starts only after the user presses Start and the gateway accepts creation. Connected and idle provider time may be billable under the provider account’s current pricing; verify pricing and model access in that account before use.

Server-side limits, not client countdowns, enforce:

- one active provider session per gateway;
- a configurable 1–30 minute input-idle timeout, with a 5-minute default;
- an implementation-local, non-resettable 120-minute safety ceiling.

The 120-minute value is a source-enforced upper bound, not an availability or uninterrupted-duration guarantee. Network loss, provider closure, stale routing authority, permission loss, or client teardown can end a session earlier.

## Privacy and security

- Provider credentials remain server-side.
- Audio uses WebRTC and is not persisted by Pi Voice.
- Transcripts, captions, inbox messages, and conversation state are bounded in memory and disappear on restart.
- Raw PCM is reduced to bounded level metadata and discarded.
- Target authority uses an exact session ID plus endpoint epoch.
- Client-delegation metadata contains no task text.
- Ending voice stops the voice generation; it does not cancel Pi work already dispatched.

## Build and test

Gateway and native-pairing page:

```bash
npm test
```

macOS policy and app source:

```bash
swift build --package-path native/mac --disable-keychain --disable-netrc -Xswiftc -warnings-as-errors
swift run --package-path native/mac --disable-keychain --disable-netrc PiVoiceMacCoreChecks
native/mac/scripts/check-parity-source.sh
native/mac/scripts/build-app.sh
```

iPhone policy core:

```bash
swift run --package-path native/phone PiVoiceCoreChecks
```

The native fake modes do not use a microphone, provider credential, paid session, or live gateway.

## Dependency note

The package manifest uses the exact repository-relative `pi-intercom` source archive under `vendor/`. It provides the native client and `offline-delivery-reject-v1` without requiring a separate package release. The active-generation human endpoint requests reject-mode delivery; the persistent roster observer remains a non-human observer. See [`docs/dependency-binding.md`](docs/dependency-binding.md) for content hashes and verification.

## License

Pi Voice source is available under the [MIT License](LICENSE). Required third-party license and notice files are retained in this repository; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The source uses system fonts and does not redistribute PP Telegraf. The checked-in `ai.strand.pivoice` iPhone identifiers are public source defaults. Changing app, Keychain, URL-routing, signing, or permission identities creates a distinct installation and does not migrate an existing app.
