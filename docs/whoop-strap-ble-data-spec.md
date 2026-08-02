# WHOOP strap BLE data spec

Implementation reference for reading data off a WHOOP strap over BLE. Written to be
sufficient on its own: an agent should be able to build a working client in any language
from this document without reading the Rust or Swift source.

## 0. How to read this document

Every claim carries a verification status. Do not silently promote one to another.

| Status | Meaning |
| --- | --- |
| **VERIFIED** | Decoded from real captured traffic, with a parser and passing tests in this repo. |
| **IMPLEMENTED** | Encoded in this repo's command catalog or state machine, but not exercised against hardware in the capture referenced below. |
| **OBSERVED** | Measured from one capture session on one device. Rates are that device's behaviour, not a specification. |
| **UNCONFIRMED** | Named in the protocol map, semantics not established. Treat the payload as opaque bytes. |

**Provenance of the measurements in this document**

- Device: WHOOP 5.0 ("Goose" generation), one unit.
- Capture window: 2026-08-01T23:35Z to 2026-08-02T12:06Z.
- Volume: 36,687 decoded frames, of which 2,492 arrived via historical sync.
- Everything under "OBSERVED" comes from that single session. A different firmware,
  wear state, or sync mode will produce different rates.

Source of truth in this repo: `Rust/core/src/protocol.rs` (framing, packet parsing),
`Rust/core/src/commands.rs` (command catalog), `Rust/core/src/historical_sync.rs`
(sync state machine), `GooseSwift/GooseBLEClient.swift` (BLE transport).

---

## 1. Transport

### 1.1 GATT services and characteristics — VERIFIED

The strap exposes two alternative vendor service UUIDs. A given unit advertises one; probe
for both.

| Role | UUID (variant A) | UUID (variant B) |
| --- | --- | --- |
| Vendor service | `fd4b0001-cce1-4033-93ce-002d5875f58a` | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` |
| Command (write) | `fd4b0002-cce1-4033-93ce-002d5875f58a` | `61080002-8d6d-82b8-614a-1c8cb0f8dcc6` |
| Notify | `fd4b0003…`, `fd4b0004…`, `fd4b0005…`, `fd4b0007…` | `61080003…`, `61080004…`, `61080005…`, `61080007…` |

- Write commands to the **command** characteristic.
- Subscribe to **all four** notify characteristics. Different packet classes arrive on
  different ones, and which is which is not stable enough to rely on.
- `…0007` doubles as the debug-menu characteristic.

Standard Bluetooth SIG services are also present and usable without any of the framing
below: Heart Rate `180D`/`2A37`, Battery `180F`/`2A19` and `2BED`, Device Information
`180A` (`2A24` model, `2A26` firmware, `2A27` hardware).

> If you only need live heart rate, use `180D`/`2A37` and stop reading here. The rest of
> this document exists for motion, history, and everything the standard profiles omit.

### 1.2 Reassembly — VERIFIED

BLE notifications do not align to frame boundaries. Maintain a per-connection byte buffer:

```
feed(chunk):
    buffer += chunk
    drop bytes from the front until buffer[0] == 0xAA   # resynchronise
    loop:
        if len(buffer) < 8: break                       # header incomplete
        declared = u16_le(buffer[2:4])
        total    = 8 + declared
        if len(buffer) < total: break                    # frame incomplete
        emit(buffer[0:total])
        buffer = buffer[total:]
        drop bytes from the front until buffer[0] == 0xAA
```

Count dropped prefix bytes; a nonzero count means desynchronisation and is worth logging.

---

## 2. Frame layer — VERIFIED

All multi-byte integers in this document are **little-endian** unless stated otherwise.

### 2.1 Layout

```
offset  size  field
0       1     0xAA            frame start
1       1     0x01            constant in frames this repo emits
2       2     declared_len    payload length + 4 (the payload CRC)
4       2     0x0000 / 0x0001 reserved; emitted as 00 01
6       2     header_crc      CRC-16/MODBUS over bytes [0..6)
8       N     payload         N = declared_len - 4
8+N     4     payload_crc     CRC-32 (IEEE, as in zlib) over payload, little-endian
```

Total frame length is `8 + declared_len`. `declared_len` must be >= 4.

### 2.2 Checksums

- **Header**: CRC-16/MODBUS (poly `0x8005` reflected, init `0xFFFF`, no final XOR) over the
  first 6 bytes, compared against bytes 6..8.
- **Payload**: standard CRC-32 over the payload bytes only, little-endian, in the last 4 bytes.

Validate both. Do not discard on failure — record the mismatch and keep the frame. Real
captures contain frames with valid headers and truncated bodies, and they still carry usable
data.

### 2.3 Truncated frames

A frame shorter than `8 + declared_len` is acceptable **only** when the header CRC is valid
and the packet type is one of the data-packet types (§3). In that case parse what is present,
mark it truncated, and skip payload CRC validation. Any other short frame is an error.

### 2.4 Building a frame

```
build_frame(payload):
    pad payload with 0x00 up to a multiple of 4 bytes
    payload_crc  = crc32(payload)            # little-endian
    declared_len = len(payload) + 4
    header       = [0xAA, 0x01] + u16_le(declared_len) + [0x00, 0x01]
    header      += u16_le(crc16_modbus(header[0:6]))
    return header + payload + u32_le(payload_crc)

build_command(sequence, command, data):
    return build_frame([0x23, sequence, command] + data)   # 0x23 = 35 = COMMAND
```

---

## 3. Payload layer — VERIFIED

Payload byte 0 is the packet type.

| Value | Name | Class |
| --- | --- | --- |
| 35 | `COMMAND` | command |
| 36 | `COMMAND_RESPONSE` | command |
| 37 | `PUFFIN_COMMAND` | command |
| 38 | `PUFFIN_COMMAND_RESPONSE` | command |
| 40 | `REALTIME_DATA` | data packet |
| 43 | `REALTIME_RAW_DATA` | data packet |
| 47 | `HISTORICAL_DATA` | data packet |
| 48 | `EVENT` | event |
| 49 | `METADATA` | opaque |
| 50 | `CONSOLE_LOGS` | opaque |
| 51 | `REALTIME_IMU_DATA_STREAM` | data packet |
| 52 | `HISTORICAL_IMU_DATA_STREAM` | data packet |
| 53 | `RELATIVE_PUFFIN_EVENTS` | event |
| 54 | `PUFFIN_EVENTS_FROM_STRAP` | event |
| 55 | `RELATIVE_BATTERY_PACK_CONSOLE_LOGS` | opaque |
| 56 | `PUFFIN_METADATA` | opaque |

### 3.1 Command — VERIFIED

```
0  packet_type = 35
1  sequence         caller-assigned, echoed in the response
2  command          opcode (§4)
3+ data             command-specific
```

### 3.2 Command response — VERIFIED

```
0  packet_type = 36
1  sequence         the strap's own sequence, NOT the request's
2  response_to      opcode being answered
3  origin_sequence  the sequence from your request — correlate on this
4  result_code
5+ data
```

| `result_code` | Meaning | Client action |
| --- | --- | --- |
| 0 | `FAILURE` | Command rejected. |
| 1 | `SUCCESS` | Payload from byte 5 is valid. |
| 2 | `PENDING` | **Not terminal.** Keep waiting on the same `origin_sequence`. |
| 3 | `UNSUPPORTED` | Not available on this firmware. Do not retry. |

`PENDING` is the most common source of bugs. The strap frequently answers `PENDING`
immediately and `SUCCESS` milliseconds later, reusing `origin_sequence`. A client that
treats the first response as terminal will read a null result. Keep the request open until
`SUCCESS`, `FAILURE`, or `UNSUPPORTED` arrives, with a timeout (this repo uses 25 s).

### 3.3 Event — VERIFIED

```
0   packet_type = 48
2   u16  event_id
4   u32  timestamp_seconds       Unix epoch seconds
8   u16  timestamp_subseconds    RTC ticks — see §6
12+ data
```

Event IDs — VERIFIED as a table, individual semantics UNCONFIRMED except where obvious:

| ID | Name | ID | Name |
| --- | --- | --- | --- |
| 0 | `UNDEFINED` | 33 | `BLE_REALTIME_HR_ON` |
| 1 | `ERROR` | 34 | `BLE_REALTIME_HR_OFF` |
| 2 | `CONSOLE_OUTPUT` | 56 | `STRAP_DRIVEN_ALARM_SET` |
| 3 | `BATTERY_LEVEL` | 57 | `STRAP_DRIVEN_ALARM_EXECUTED` |
| 4 | `SYSTEM_CONTROL` | 58 | `APP_DRIVEN_ALARM_EXECUTED` |
| 7 | `CHARGING_ON` | 59 | `STRAP_DRIVEN_ALARM_DISABLED` |
| 8 | `CHARGING_OFF` | 60 | `HAPTICS_FIRED` |
| 9 | `WRIST_ON` | 63 | `EXTENDED_BATTERY_INFORMATION` |
| 10 | `WRIST_OFF` | 96 | `HIGH_FREQ_SYNC_PROMPT` |
| 11 | `BLE_CONNECTION_UP` | 97 | `HIGH_FREQ_SYNC_ENABLED` |
| 12 | `BLE_CONNECTION_DOWN` | 98 | `HIGH_FREQ_SYNC_DISABLED` |
| 13 | `RTC_LOST` | 100 | `HAPTICS_TERMINATED` |
| 14 | `DOUBLE_TAP` | 109 | `BATTERY_PACK_INFO` |
| 15 | `BOOT` | 123 | `GENERIC_FIRMWARE_EVENT` |
| 16 | `SET_RTC` | 17 | `TEMPERATURE_LEVEL` |
| 18 | `PAIRING_MODE` | 28 | `FLASH_INIT_COMPLETE` |
| 29 | `STRAP_CONDITION_REPORT` | | |

`WRIST_ON` / `WRIST_OFF` are the reliable wear-state signal. `RTC_LOST` invalidates
timestamp trust until a subsequent `SET_RTC` (§6.3).

---

## 4. Command catalog — IMPLEMENTED

75 opcodes. Risk classes:

- **ReadOnly** — no device state change. Safe to issue freely.
- **UserVisibleStateChange** — user-perceptible effect (haptics, streaming, alarms).
- **CriticalStateChange** — firmware, persistent config, reboot. **Do not issue without an
  explicit confirmation step.** Several can brick or reconfigure the strap.

### Identity and capability

| # | Command | Risk | Purpose |
| --- | --- | --- | --- |
| 1 | `link_valid` | ReadOnly | Confirm link-valid protocol state. |
| 2 | `get_max_protocol_version` | ReadOnly | Maximum supported protocol version. |
| 7 | `report_version_info` | ReadOnly | Strap version information. |
| 35 | `get_hello_harvard` | ReadOnly | Legacy Gen4 hello. |
| 145 | `get_hello` | ReadOnly | Identity and protocol hello. Use as the handshake. |

### Sensor streaming

| # | Command | Risk | Purpose |
| --- | --- | --- | --- |
| 3 | `toggle_realtime_hr` | UserVisible | Realtime HR packets. **The one that works on 5.0.** |
| 14 | `toggle_generic_hr_profile` | UserVisible | Route HR to the standard `180D` profile. |
| 16 | `toggle_r7_data_collection` | UserVisible | R7 collection. |
| 63 | `send_r10_r11_realtime` | UserVisible | R10/R11 raw packets. **Returns `UNSUPPORTED` on 5.0.** |
| 81 / 82 | `start_raw_data` / `stop_raw_data` | UserVisible | Realtime raw stream. |
| 105 / 106 | `toggle_imu_mode_historical` / `toggle_imu_mode` | UserVisible | IMU stream mode. |
| 107 | `enable_optical_data` | UserVisible | Realtime optical R20. |
| 108 | `toggle_optical_mode` | UserVisible | Optical stream mode. |
| 124 / 125 | `toggle_labrador_data_generation` / `toggle_labrador_raw_save` | UserVisible | Raw ECG generation/save. |
| 139 | `toggle_labrador_filtered` | UserVisible | Filtered ECG stream. |

### Historical sync

| # | Command | Risk | Purpose |
| --- | --- | --- | --- |
| 20 | `abort_historical_transmits` | UserVisible | Abort active transfer; use to recover. |
| 22 | `send_historical_data` | UserVisible | Request the transfer. |
| 23 | `historical_data_result` | UserVisible | Acknowledge a completed chunk. |
| 33 | `set_read_pointer` | UserVisible | Move the read pointer. |
| 34 | `get_data_range` | ReadOnly | Available history range. |
| 96 / 97 | `enter_high_freq_sync` / `exit_high_freq_sync` | UserVisible | High-frequency sync mode. |

### Clock

| # | Command | Risk | Purpose |
| --- | --- | --- | --- |
| 10 | `set_clock` | UserVisible | Set RTC seconds and subseconds. |
| 11 | `get_clock` | ReadOnly | Read RTC. Use to measure strap-vs-host offset. |

### Battery, wrist, identity strings

| # | Command | Risk | Purpose |
| --- | --- | --- | --- |
| 26 | `get_battery_level` | ReadOnly | Battery level. |
| 98 | `get_extended_battery_info` | ReadOnly | Extended fuel-gauge info. |
| 151 | `get_battery_pack_info` | ReadOnly | Battery-pack info. |
| 84 | `get_body_location_and_status` | ReadOnly | Body location and status. |
| 123 | `select_wrist` | UserVisible | Left/right wrist selection. |
| 140 / 141 | `set_advertising_name` / `get_advertising_name` | UserVisible / ReadOnly | Advertising name. |
| 76 / 77 | `get_advertising_name_harvard` / `set_advertising_name_harvard` | ReadOnly / UserVisible | Legacy name. |

### Alarms and haptics

| # | Command | Risk | Purpose |
| --- | --- | --- | --- |
| 66 / 67 | `set_alarm_time` / `get_alarm_time` | UserVisible / ReadOnly | Strap alarm. |
| 68 / 69 | `run_alarm` / `disable_alarm` | UserVisible | Trigger / disable alarm. |
| 79 / 80 | `run_haptics_pattern` / `get_all_haptics_pattern` | UserVisible / ReadOnly | Haptic patterns. |
| 19 | `run_haptic_pattern_maverick` | UserVisible | Maverick haptic pattern. |
| 122 | `stop_haptics` | UserVisible | Stop haptics. |

### CriticalStateChange — confirmation required

| # | Command | Area |
| --- | --- | --- |
| 25, 29, 32 | `force_trim`, `reboot_strap`, `power_cycle_strap` | Reboot / maintenance |
| 36, 37, 38, 45, 83, 142, 143, 144 | firmware load / DFU / verify | Firmware |
| 39–44 | LED drive, TIA gain, bias offset (set/get) | Optical AFE — `get_*` are ReadOnly |
| 52, 53 | `set_dp_type`, `force_dp_type` | Historical packet type selection |
| 115, 116, 119, 121 | device config key exchange and values | Persistent config — `get_device_config_value` is ReadOnly |
| 117, 118, 120, 128 | feature flag key exchange and values | Feature flags — `get_feature_flag_value` is ReadOnly |
| 131, 132 | `set_research_packet`, `get_research_packet` | Research packets — `get_*` is ReadOnly |
| 153, 154 | `toggle_persistent_r20`, `toggle_persistent_r21` | Persistent sensor config |

---

## 5. Data packets — VERIFIED

Packet types 40, 43, 47, 51, 52 share one 13-byte header.

```
0   packet_type
1   packet_k            family selector — determines the body layout
2   status_or_stream
3   u32  counter_or_page
7   u32  timestamp_seconds      Unix epoch seconds
11  u16  timestamp_subseconds   RTC ticks — see §6
13+ body                        layout depends on packet_k
```

**`packet_k` 2 is the exception: it does not use this header.** See §5.2.

### 5.1 Family map

| `packet_k` | Domain | Body | Status |
| --- | --- | --- | --- |
| 2 | realtime status | Heart rate at a fixed offset | VERIFIED |
| 7 | legacy raw / research counted | HR marker at offset 27 | VERIFIED (marker only) |
| 9, 12, 24 | normal history with HR marker | HR marker at offset 17 | VERIFIED (marker only) |
| 18 | normal history with HR marker | HR marker at offset 14 | VERIFIED |
| 10 | raw motion stream | 6 axes × 100 × i16 | VERIFIED |
| 21 | raw motion stream | 2 groups × 3 axes × i16 | VERIFIED |
| 11 | raw stream counted | — | UNCONFIRMED |
| 16 | raw ECG (Labrador) | — | UNCONFIRMED |
| 17 | optical / filtered ECG | flags, channels, sample series | VERIFIED (structure) |
| 19, 22 | research packet | — | UNCONFIRMED |
| 20 | raw / research counted | — | UNCONFIRMED |
| 25, 26 | pulse information | — | UNCONFIRMED |

### 5.2 `packet_k` 2 — realtime status, carries live HR — VERIFIED

The highest-volume packet and the live heart-rate source on WHOOP 5.0.

```
heart_rate_bpm = payload[8]      # 0 means "no reading", not zero BPM
```

**This family omits the 13-byte header.** The generic parse still reads bytes 7..11 and 11..13
as `timestamp_seconds` / `timestamp_subseconds`, but for `packet_k == 2` those are unrelated
payload bytes. Byte 8 — the HR value — falls inside what the generic parser calls
`timestamp_seconds`.

**Therefore: never trust `timestamp_seconds` or `timestamp_subseconds` from `packet_k` 2.**
Timestamp these samples with host receive time. Verified consequence: in the reference
capture, only `packet_k` 2 frames carried a `timestamp_subseconds` above the valid tick range
(max 65284 against a 32767 ceiling), which is precisely how they are detected and rejected.

### 5.3 `packet_k` 21 — raw motion / IMU — VERIFIED

Two groups of three i16 axis series.

```
14   u16  field_x
16   u16  group_1_count      sample count for group 1 axes
20        group_1_axis_0     i16[group_1_count]
220       group_1_axis_1     i16[group_1_count]
420       group_1_axis_2     i16[group_1_count]
622  u16  group_2_count      sample count for group 2 axes
632       group_2_axis_0     i16[group_2_count]
832       group_2_axis_1     i16[group_2_count]
1032      group_2_axis_2     i16[group_2_count]
```

OBSERVED: both counts are 100, giving 600 i16 samples per frame, one frame per 2 s — i.e.
**50 Hz per axis**, six axes. That 50 Hz matches the sample rate this repo's step estimator
assumes.

The two groups are almost certainly accelerometer and gyroscope by analogy with `packet_k` 10,
which names its axes explicitly — but this repo does not label them, so the mapping is
UNCONFIRMED. Treat as "group 1 axes 0-2" and "group 2 axes 0-2" until validated against a
known motion.

### 5.4 `packet_k` 10 — raw motion (K10) — VERIFIED

Fixed offsets, 100 i16 samples each, axes named:

| Offset | Axis |
| --- | --- |
| 85 | `accelerometer_x` |
| 285 | `accelerometer_y` |
| 485 | `accelerometer_z` |
| 688 | `gyroscope_x` |
| 888 | `gyroscope_y` |
| 1088 | `gyroscope_z` |

Not observed in the reference capture: WHOOP 5.0 answers the command that enables these
(`send_r10_r11_realtime`, 63) with `UNSUPPORTED`.

### 5.5 Normal-history families (7, 9, 12, 18, 24) — VERIFIED

The body is not decoded. What is extracted is a single heart-rate marker byte whose offset
depends on the family:

| `packet_k` | HR marker offset |
| --- | --- |
| 7 | 27 |
| 9, 12, 24 | 17 |
| 18 | 14 |

A nonzero marker means an HR reading is present; the value is the BPM. `packet_k` 18 is the
historical HR carrier in practice — 711 frames in the reference capture, all decoding.

### 5.6 `packet_k` 17 — optical / filtered ECG — VERIFIED (structure only)

Contains flags (with bits 9 and 11 called out), a channel/gain array, a sample count, and an
i16 sample series. Field semantics and units are UNCONFIRMED.

---

## 6. Timestamps — VERIFIED, and the single most important section

### 6.1 Sub-seconds are RTC ticks, not milliseconds

`timestamp_subseconds` counts ticks of the strap's **32.768 kHz** RTC. A full second is
32768 ticks, so the valid range is `0..=32767`.

```
if subseconds >= 32768:
    # not a tick count — this frame's header is not a real timestamp
    fall back to host receive time
else:
    millis   = subseconds * 1000 / 32768
    unix_ms  = timestamp_seconds * 1000 + millis
```

**Getting this wrong is silent and severe.** Treating the field as milliseconds and rejecting
values above 999 discards ~99% of historical samples — in the reference capture, 2,461 of
2,492. Those samples then fall back to receive time, so an entire night downloaded in one
burst collapses into the download window: 2,492 frames spanning 23:42–02:33 all landed at
11:29–12:05, producing duplicate timestamps on 1,750 of 1,760 motion samples and 693 of 711
HR samples. Downstream, a sleep-window heuristic read the resulting empty stretch as a single
614-minute sleep block and scored a night that never happened.

Validate an implementation against this: sub-second values must be spread across `0..32767`,
and per-frame timestamps within a historical burst must be **monotonic and unique**, not
clustered at the download time.

### 6.2 Plausibility gate

Independently of sub-seconds, require
`946684800 <= timestamp_seconds <= 4102444800` (2000-01-01 .. 2100-01-01). Outside that, the
header is not a timestamp — fall back to receive time.

### 6.3 Trust rules

1. `packet_k` 2 — always use host receive time (§5.2).
2. After an `RTC_LOST` event, device timestamps are untrustworthy until `SET_RTC`.
3. Historical packets — **always** prefer the device timestamp. Receive time is meaningless
   for them; it is the download moment, not the recording moment.
4. Realtime packets other than `packet_k` 2 — device timestamp when it passes the gates,
   otherwise receive time.
5. Always record which source was used per sample. Downstream consumers need to distinguish
   a recorded time from an arrival time.

Use `get_clock` (11) to measure strap-vs-host offset rather than assuming they agree.

---

## 7. Historical sync — IMPLEMENTED, flow VERIFIED against capture

### 7.1 Flow

```
Connect
  → [optional] GET_DATA_RANGE (34)        read what is available
  → SEND_HISTORICAL_DATA (22)             request the transfer
  → consume METADATA + data packets       HistoryStart … readings … HistoryEnd
  → HISTORICAL_DATA_RESULT (23)           acknowledge
  → repeat until HistoryComplete
```

State machine: `Idle → Connected → RangeRequested → Transferring → AckPending → Complete`,
with `Blocked` and `Failed` as terminals. Recovery after an idle stall: issue
`ABORT_HISTORICAL_TRANSMITS` (20), then retry once.

### 7.2 Metadata markers

The strap delimits the stream with metadata frames: `HistoryStart`, `HistoryEnd`, and
`HistoryComplete`. Data packets arrive between `HistoryStart` and `HistoryEnd`.
`HistoryComplete` ends the session.

### 7.3 Acknowledgement — handle with care

After each `HistoryEnd` you send `HISTORICAL_DATA_RESULT` (23) carrying the position from the
`HistoryEnd` body. This advances the strap's read pointer.

**Acknowledging advances the pointer whether or not you successfully stored the data.** A
client that acks before durably persisting can move past records it never kept. Persist
first, then ack.

### 7.4 Empty responses are normal and not necessarily an error

OBSERVED: in one session, 462 consecutive request/response cycles completed cleanly —
`GET_DATA_RANGE` SUCCESS, `SEND_HISTORICAL_DATA` SUCCESS, `HistoryStart` then immediately
`HistoryEnd` — with **zero data packets** between the markers. A successful handshake does not
imply data. Instrument the count of data packets per `HistoryStart`/`HistoryEnd` pair, not
just command results, or a client will look healthy while delivering nothing.

Whether this is exhaustion of available history, a pointer problem, or contention with an
active realtime stream is UNCONFIRMED.

---

## 8. What the strap actually gives you, and how often

OBSERVED, single session. Rates are medians of inter-frame device-time deltas.

| Data | Source | Transport | Cadence | Effective rate | Time basis |
| --- | --- | --- | --- | --- | --- |
| Heart rate (live) | `packet_k` 2 | realtime | ~1 s between frames | **~1 Hz** | receive time |
| Heart rate (history) | `packet_k` 18 | historical | ~13 s between frames | ~1 sample / 13 s | device time |
| Motion / IMU (history) | `packet_k` 21 | historical | 2 s between frames | **50 Hz × 6 axes** | device time |
| Motion / IMU (live) | `packet_k` 21 | realtime raw | ~1 s between frames | 50 Hz × 6 axes | device time |
| Pulse information | `packet_k` 26 | historical | ~15.5 s | UNCONFIRMED semantics | device time |
| Counted raw/research | `packet_k` 20 | both | ~1 s | UNCONFIRMED semantics | device time |
| Wear state, charging, taps, alarms | events | async | on occurrence | event-driven | device time |
| Battery | `180F` or cmd 26/98/151 | poll | on demand | — | — |

The "time basis" column is not incidental. Cadence for `packet_k` 2 **must** be measured from
host receive time, because its header timestamps are not timestamps (§5.2). Measuring it from
the header instead yields a plausible-looking but entirely fictional ~45 s.

Volumes in that session: 33,199 `packet_k` 2 frames — of which 30,269 decoded a body summary,
and **all 30,269 carried a heart rate** — plus 1,760 `packet_k` 21, 711 `packet_k` 18,
21 `packet_k` 26, 20 `packet_k` 20.

At ~1 Hz the vendor stream is a perfectly good live-HR source. The standard `180D`/`2A37`
profile remains the simpler option if HR is all you need, and `toggle_generic_hr_profile` (14)
routes HR there.

### 8.1 What is NOT available

- **Step count.** There is no step-counter field in any observed packet family. A discovery
  pass across all 36,687 frames found zero candidate counter fields. Steps must be derived
  from the 50 Hz IMU stream, not read from the strap.
- **Sleep stages, recovery, strain scores.** The strap ships sensor data, not WHOOP's derived
  metrics. Everything of that kind must be computed locally.
- **SpO2, skin temperature as decoded values.** Temperature-bearing frames are observed, but
  units and offsets are UNCONFIRMED.

---

## 9. Implementation checklist

1. Scan for both vendor service UUIDs; subscribe to all four notify characteristics.
2. Implement the 0xAA reassembly buffer (§1.2) before anything else.
3. Validate header CRC-16/MODBUS and payload CRC-32; record mismatches, do not discard.
4. Correlate responses on `origin_sequence` (byte 3), and **treat `PENDING` as non-terminal**.
5. Handshake with `get_hello` (145).
6. Enable live HR with `toggle_realtime_hr` (3). Do not use `send_r10_r11_realtime` (63) on
   5.0 — it returns `UNSUPPORTED`.
7. Decode sub-seconds as 32.768 kHz ticks (§6.1). Assert sub-second values spread across
   `0..32767` and that historical timestamps are unique and monotonic.
8. Special-case `packet_k` 2: HR at byte 8, header timestamps invalid.
9. For historical sync, persist before acknowledging (§7.3), and count data packets per
   `HistoryStart`/`HistoryEnd` pair (§7.4).
10. Record per sample which timestamp source was used.
11. Gate every CriticalStateChange command behind explicit confirmation.

## 10. Pitfalls that cost real debugging time

| Symptom | Cause |
| --- | --- |
| A whole night of data lands in a few minutes | Sub-seconds read as milliseconds; samples rejected and stamped with receive time (§6.1). |
| Live HR reads as a huge or nonsensical timestamp | Using `packet_k` 2 header timestamps, which are unrelated payload bytes (§5.2). |
| Live HR cadence looks oddly slow (tens of seconds) | Same cause, one step removed: deriving the *rate* from `packet_k` 2 header timestamps. The number looks plausible, so it does not announce itself as wrong. Measure from receive time (§8). |
| Commands appear to return nothing | Treating `PENDING` (2) as terminal (§3.2). |
| Sync reports success but no data arrives | Counting command results instead of data packets per marker pair (§7.4). |
| History gaps after a crash | Acknowledging before persisting (§7.3). |
| Step count never appears | There is no step counter on the wire (§8.1). |
