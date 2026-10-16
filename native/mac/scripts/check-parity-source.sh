#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/Sources/PiVoiceMac/PiVoiceMacApp.swift"
VISUALS="$ROOT/Sources/PiVoiceMac/PiVoiceMacVisuals.swift"
CORE="$ROOT/Sources/PiVoiceMacCore/VoiceSession.swift"
GATEWAY="$ROOT/Sources/PiVoiceMac/GatewayClient.swift"
SECURITY="$ROOT/Sources/PiVoiceMacSecurity/RejectingRedirectDelegate.swift"

require() {
  grep -Fq "$1" "$2" || { printf 'missing required source contract: %s in %s\n' "$1" "$2" >&2; exit 1; }
}
reject() {
  if grep -Fq "$1" "$2"; then
    printf 'obsolete presentation contract remains: %s in %s\n' "$1" "$2" >&2
    exit 1
  fi
}

require 'private var captionThread: some View' "$APP"
require 'let segments = model.coordinator.captionThread' "$APP"
require 'lineLimit(isNewest ? 4 : 2)' "$APP"
require '.voiceUser' "$APP"
require '.voiceAgent' "$APP"
require 'popoverVisible && !reduceMotion' "$APP"
reject 'audioLevelSurface' "$APP"
reject 'captionCard' "$APP"
reject 'Text("Captions")' "$APP"
reject 'Text("—")' "$APP"

require 'minimumInterval: 1.0 / 30.0' "$VISUALS"
require 'ProcessInfo.processInfo.systemUptime' "$VISUALS"
require 'attackDuration: 0.14' "$VISUALS"
require 'releaseDuration: 0.28' "$VISUALS"
require 'releaseDuration: 0.3' "$VISUALS"
require 'transaction.disablesAnimations = true' "$VISUALS"
reject 'timeline.date.timeIntervalSinceReferenceDate' "$VISUALS"

require 'private var captionThreadStore = BoundedCaptionThread()' "$CORE"
require 'guard case .active = phase, let generation = authority?.generation else { return [] }' "$CORE"
require 'captionThreadStore.clear()' "$CORE"

require 'explicitReconnectRequired = true' "$CORE"
require '!coordinator.explicitReconnectRequired' "$APP"
require 'func checkProviderStatus() async' "$APP"
require 'retainAuthorityAfterUnconfirmedEnd(error.localizedDescription)' "$CORE"
require 'lastEndGeneration == current.generation' "$CORE"
require 'if current != nil { releaseAfterConfirmedProviderClosure() }' "$CORE"
require '(closureRecoveryEpoch == nil || closureRecoveryMayResumeReady)' "$CORE"
require 'wantsAutomaticConnection = false' "$APP"
require 'automaticConnectionTask?.cancel()' "$APP"
require 'if let message = model.closureStatusMessage {' "$APP"
require 'Label(model.busy ? "Checking…" : "Check status", systemImage: "checkmark.shield")' "$APP"
require 'No exact closure receipt is available yet. Authority remains retained; nothing was restarted or replayed.' "$APP"
require 'Startup allocation is unknown and no exact generation was returned.' "$APP"
require 'receipt.matches(session: socketSession, task: socket)' "$GATEWAY"
require 'makeWebSocketConfiguration(cookieStorage: cookieStorage)' "$GATEWAY"
require 'receipt.webSocketCloseCode == 4003' "$GATEWAY"
require 'code == "voice_connection_lost"' "$GATEWAY"
require 'code == "stale_voice_connection"' "$GATEWAY"
require 'willPerformHTTPRedirection' "$SECURITY"
require 'completionHandler(nil)' "$SECURITY"
require 'didCompleteWithError error: Error?' "$SECURITY"
require 'didCloseWith closeCode: URLSessionWebSocketTask.CloseCode' "$SECURITY"

printf 'PiVoiceMacParitySourceChecks: presentation and transport-recovery contracts passed\n'
