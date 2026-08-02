# Live HR Lab — Design

Date: 2026-08-02
Status: Approved, ready for implementation planning

## Problem

A WHOOP 5.0 band connects and reaches `ready`, but no live heart rate appears anywhere in
the app. Investigation traced this to two independent defects.

### Defect 1: the band rejects the stream-enable command

`startMovementHeartRateCapture` writes two commands 0.25s apart
(`GooseBLEClient.swift:529`):

| Order | Opcode | Name |
| --- | --- | --- |
| 1 | 3 | `TOGGLE_REALTIME_HR_ON` |
| 2 | 63 | `SEND_R10_R11_REALTIME_ON` |

On the affected band, command 63 returns `UNSUPPORTED` (result code 3, per
`commandResultName`, `GooseBLEClient+Parsing.swift:550`).

Command 63 enables the K10/K11 realtime stream. The app's **only** live-HR source is byte 17
of the K10 raw motion packet (`Rust/core/src/protocol.rs:588`):

```rust
Some(DataPacketBodySummary::RawMotionK10 {
    heart_rate: payload.get(17).copied(),
```

With no K10 packets, `interpretation.heartRateBPM` is nil, so `recordLiveHeartRate` never
fires (`GooseAppModel+NotificationPipeline.swift:633`), `liveHeartRateBPM` stays nil, and every
surface falls back to `liveHeartRateSource`, which defaults to `"waiting"`
(`GooseBLEClient.swift:12`).

### Defect 2: the app cannot show what happened

Diagnosing Defect 1 took several manual round trips because the app collapses all
sensor-stream command responses into a single string. Each response overwrites the previous
one (`GooseBLEClient+HistoricalHandlers.swift:99`):

```swift
lastPhysiologyCommandSummary = "\(commandName) seq \(payload[3]) \(result)"
physiologyCaptureStatus = lastPhysiologyCommandSummary
```

Command 3's result is therefore destroyed by command 63's, 0.25s later. Whether command 3
succeeded — which determines the entire fix direction — is currently unknowable from the UI.

Contributing UI problems:

- The `Start Movement + HR Capture` action row's badge is derived only from
  `connectionState` (`MoreDebugViews.swift:257`), so `.pending` means "tappable", not "in
  progress". It never changes after a tap, making a working button look dead.
- The `Capture` info row renders `.stale` for both success and every failure reason
  (`MoreDebugViews.swift:203`), so the badge cannot distinguish them.
- Discovered GATT services/characteristics are only written to the event log and then
  discarded, so there is no way to check whether the band exposes the standard heart-rate
  characteristic `2A37`.

## Goal

Get live HR working. This page is instrumentation in service of that, not a product feature.

The immediate question it must answer: **did command 3 succeed?**

- If yes, the band streams realtime HR by some route other than K10. The standard BLE HR
  path is already fully built — the app subscribes to `2A37` when present
  (`notificationCandidate`, `GooseBLEClient+Commands.swift:752`) and parses it into
  `recordLiveHeartRate(source: "ble.hr.standard")` (`GooseBLEClient+Parsing.swift:16`) — so the
  fix may be small.
- If no, this firmware does not accept these opcodes and we need to find ones it does.

## Key design decision

The codebase already contains two command paths, and one is built correctly:

| | Sensor stream commands | Debug research commands |
| --- | --- | --- |
| Entry point | `writeSensorStreamCommands` | `sendDebugResearchCommand` |
| Tracking | `physiologyCaptureStatus` — one `String` | `pendingDebugCommands` → `debugCommandResponses` |
| Result | each response clobbers the last | full history with request + response hex |

`GooseDebugCommandResponse` (`GooseBLETypes.swift:129`) already carries opcode, sequence,
`requestedAt`/`completedAt`, status, result, request payload/frame hex, and response body hex.

**Therefore: do not build new tracking. Route sensor-stream commands through the tracking the
debug path already uses.** Every view in this design is then a view over one unified history.

## Components

### 1. Unify command tracking

Files: `GooseBLEClient+Commands.swift`, `GooseBLEClient+HistoricalHandlers.swift`

- `writeSensorStreamCommands` registers each command in `pendingDebugCommands`, mirroring
  `sendDebugResearchCommand` (`GooseBLEClient+UserActions.swift:81-100`).
- `handleSensorStreamValue` resolves the pending entry into `debugCommandResponses` instead of
  overwriting `physiologyCaptureStatus`.
- `physiologyCaptureStatus` and `lastPhysiologyCommandSummary` are retained so existing UI keeps
  working, but are no longer the source of truth.
- The five guard failures in `writeSensorStreamCommands` (historical sync in flight, no command
  characteristic, connection not ready, no `fd4b0002` V5 framing, characteristic not writable)
  record a `blocked` entry in the history instead of silently overwriting a string.

### 2. Retain the GATT tree

File: `GooseBLEClient`, populated in `processDiscoveredCharacteristics`
(`GooseBLEClient+Commands.swift:838`)

Add a `@Published` typed collection of discovered services and their characteristics
(UUID + properties). No behavioural change; purely retaining what is currently logged and
discarded. This answers whether `180D`/`2A37` exist on the band.

### 3. New route and view

- `MoreRoute.liveHRLab`, added to `MoreRoute.developerToolRoutes`
  (`MoreRouteModels.swift:97`), with title/subtitle/systemImage/status-keypath entries added to
  the four `switch` statements in that file.
- `MoreLiveHRLabView`, wired in `MoreView.swift:95` alongside the other routes.

Sections, in order:

1. **Live HR state** — `liveHeartRateBPM`, `liveHeartRateSource`, age from
   `liveHeartRateUpdatedAt`.
2. **Packet flow** — per-family counters (K10, K11, K2, R21, optical, HR) with a **reset**
   action, so a toggle's effect can be measured before/after. See "Packet counters must be
   independent" below — this cannot reuse the existing capture counters.
3. **Command history** — the unified `debugCommandResponses` list: name, opcode, sequence,
   result, request hex, response hex, timestamp. The primary diagnostic.
4. **Known sequences** — one-tap Start/Stop Movement+HR and Start/Stop Physiology, reusing the
   existing functions unchanged.
5. **Curated probes** — candidate opcodes drawn from `SensorStreamCommandKind.responseNames`
   (`GooseBLEClient.swift:575`) and `debugResearchCommandDefinitions`
   (`GooseBLEClient.swift:723`), each labelled with its expected effect, one tap each.
6. **Free-form sender** — opcode (0–255) plus payload hex, validated before write.
7. **GATT dump** — collapsible; `180D` and `2A37` visually called out.

### 4. Packet counters must be independent

The existing per-family packet counters cannot be reused. `recordHealthPacketCaptureFamily`
early-returns unless a capture session is running
(`GooseAppModel+PacketPublishing.swift:6-12`):

```swift
func recordHealthPacketCaptureFamily(_ family: HealthPacketCaptureFamily, capturedAt: Date) {
  guard activeHealthPacketCapture != nil else {
    return
  }
```

`applyHealthPacketCaptureFamilySnapshot` has the same guard. The counts in
`updateHealthPacketCaptureTargetSummary` (`:319-341`) are local variables inside a
summary-string builder, not reusable published state.

The Lab therefore maintains its own lightweight counter: a `@Published [UInt8: Int]` keyed by
packet type, incremented in `handleParsedNotificationFrame`
(`GooseAppModel+NotificationPipeline.swift:613`) where `interpretation.packetType` is already
available, plus a reset action and a `lastPacketAt` timestamp. This is independent of
`activeHealthPacketCapture`, so the Lab works on a plain connection with no capture running —
which is the situation the user is actually in.

## Data flow

```
write   → writeSensorStreamCommands → pendingDebugCommands[seq]
reply   → handleSensorStreamValue   → resolve seq → debugCommandResponses (@Published) → view
packets → handleParsedNotificationFrame → Lab packet counters (@Published) → view
```

## Error handling

- Existing guard failures surface as `blocked` history entries carrying their specific reason
  string, rather than being lost.
- Free-form sender validates that the opcode parses to `UInt8` and the payload is valid,
  even-length hex. Invalid input shows an inline error and performs no write.
- Command timeouts already exist for debug commands via `scheduleDebugCommandTimeout`
  (`GooseBLEClient+UserActions.swift:98`); unified sensor-stream commands inherit this, so a
  command that never receives a reply resolves as timed out rather than hanging as pending.

## Testing

This project has **no Swift test target** — `grep -c Test GooseSwift.xcodeproj/project.pbxproj`
returns 0, and only `Rust/core` has tests.

Agreed approach: **verify on device**, and keep new logic thin enough not to require unit tests.
The only piece with real logic is hex/opcode validation in the free-form sender.

Adding a Swift XCTest target is worthwhile but is separate work, deliberately not bundled here.

Device verification steps:

1. Build and install to the physical iPhone (see README "Reinstall On A Device").
2. Connect the band, wait for `ready`.
3. Open More → Developer → Live HR Lab.
4. Reset packet counters, tap Start Movement + HR Capture.
5. Confirm the history shows **two** entries — opcode 3 and opcode 63 — each with its own
   result. This is the acceptance criterion for Defect 2.
6. Record whether `2A37` appears in the GATT dump.

## Out of scope

- Blind 0–255 opcode enumeration. The opcode space contains `WRITE_CONFIG`, `FIRMWARE_UPDATE`,
  and `REBOOT` — families the existing catalog already marks `.blocked`
  (`MoreCaptureViews.swift:18-25`). A curated candidate list gives equal coverage of the
  stream-enable family without risking a destructive write to the band.
- Changes to HR parsing once packets arrive. This page exists to determine why nothing arrives.
- Auto-starting the HR stream on connect, and the misleading badge semantics on the existing
  Debug page. Both are real, both are follow-ups once the root cause is known.

## Follow-ups this work will inform

- Whether live HR should auto-start on connect, or be a user-facing toggle (battery trade-off:
  realtime streaming meaningfully drains the band).
- Whether `MoreStatusKind` needs a distinct state for "action available" versus "in progress",
  since `.pending` currently means both.
