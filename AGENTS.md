# AGENTS.md

SmackToFix is a menu-bar-only macOS app. The desktop glitches like a dying CRT. A slap on the aluminum chassis, heard through the built-in microphone, restores the picture. The joke is the product. Do not turn it into a general audio utility, a screen recorder, or a Dock app.

The UI copy and this file are English. Reply to the author in Turkish when they write in Turkish.

## Build, test, relaunch

```bash
xcodebuild -project SmackToFix.xcodeproj -scheme SmackToFix -destination 'platform=macOS' -quiet test
```

The app is `LSUIElement`. Launch the bundle with `open`, then kill by name:

```bash
pkill -9 -x SmackToFix
open ~/Library/Developer/Xcode/DerivedData/SmackToFix-*/Build/Products/Debug/SmackToFix.app
```

Executing the binary directly never creates the status item. After a rebuild, Screen Recording permission often needs to be toggled off and on in System Settings, because the ad-hoc signature changed.

Target facts: macOS 14+, Swift 5 language mode, App Sandbox off, `CODE_SIGN_IDENTITY = "-"`, `ENABLE_DEBUG_DYLIB = NO`, bundle id `com.smacktofix.SmackToFix`. `scripts/build-release.sh` produces a universal (arm64 and x86_64) `dist/SmackToFix.zip` and `dist/SmackToFix.dmg`. A `v*` tag publishes both. People install with `brew install --cask desxz/smacktofix/smacktofix` from the `desxz/homebrew-smacktofix` tap, or by dragging the dmg into Applications. The ad-hoc signature is not notarized, so a browser download needs right-click Open the first time. Do not add a curl-pipe installer.

## Where things live

| File | Job |
| --- | --- |
| `AppDelegate.swift` | `@main`, `GlitchSession`, permissions, Option-Escape, the silent-mic retry |
| `MenuBarController.swift` | Status item, menu, the 18pt template television |
| `ImpactDetector.swift` | Pure slap classifier plus the `AVAudioEngine` tap |
| `CRTAudio.swift` | Procedural buzz and pop on that same engine |
| `SensitivityTestPanel.swift` | The meter. `heardPackets == 0` is “Waiting for the microphone…” |
| `AppSettings.swift` | Frequency and `slapThreshold.v2` |
| `OverlayWindowManager.swift` | Click-through windows and ScreenCaptureKit |
| `GlitchFrameProcessor.swift` | Core Image: RGB split, displacement, stripes, roll |
| `CRTGlitchView.swift` | Collapse animation and the capture-denied veil |
| `SmackToFixTests/ImpactDetectorTests.swift` | Classifier only. No microphone. |
| `scripts/build-release.sh` | Universal Release zip and dmg |

`assets/logo.png` is the README mark. `SmackToFix/AppIcon.icns` is the Finder icon. The menu bar does not use either of them.

## Session rules

`GlitchSession` is `@MainActor`. Phases are `idle`, `glitching`, `collapsing`.

- No glitch in the first 30 seconds after launch. **Trigger Glitch Now** ignores that.
- Frequency `0` is about 45–90 minutes, `0.5` (default) is about 4–8 minutes, `1` is about 20–45 seconds. The mapping is a log lerp in `AppSettings.intervalRange`.
- A glitch gives up after 75 seconds.
- Microphone and screen capture run only during a glitch or an open sensitivity test. `finishCollapse` stops the detector when the test panel is closed.
- The overlay is borderless, `ignoresMouseEvents = true`, and cannot become key. ScreenCaptureKit must exclude the overlay window IDs. If capture is denied, show the veil and let clicks through.
- Option-Escape is a Carbon `RegisterEventHotKey` (key code 53, option). It must keep working while the app is not focused, without an Accessibility prompt.

## The microphone graph

One `AVAudioEngine`, created with `ImpactDetector` at launch, is shared by the tap and `CRTAudio`. Do not add a second engine.

`start()` order is load-bearing:

1. Read the input format. If `outputFormat` is 0 Hz or 0 channels, fall back to `inputFormat`.
2. `installTap` at 1024 frames.
3. `prepare()`, then `start()`.
4. Only then call `outputPrepare`, which connects the player.

Two changes have already shipped a meter that never moves:

- `AudioUnitSetProperty(..., kAudioOutputUnitProperty_CurrentDevice)` on `inputNode` sets the output hardware format to 0 Hz / 0 channels. `start()` then throws **-10875** (`IsFormatSampleRateAndChannelCountValid`) or `canPerformIO`. The UI says **Microphone graph didn't start.** The default input on the development machine is already **MacBook Pro Microphone**. Do not put device selection back.
- Connecting the player, or calling `engine.prepare()` from `CRTAudio`, before `engine.start()` throws the same -10875. `CRTAudio.attach()` must not prepare the engine itself. `CRTAudio.stop()` stops the player only. `ImpactDetector.stop()` is what stops the engine, and it waits until the collapse finishes so the pop can play.

`handle` ignores buffers whose `floatChannelData` is nil, so those buffers do not increment `heardPackets`.

The first `start()` immediately after the user presses **Allow** can succeed and still deliver nothing. `scheduleSilentMicrophoneRetry` waits 400 ms. If `heardPackets` is still 0 and a test or a glitch is still listening, it `stop()`s and `start()`s once. That is the same recovery as closing and reopening the test panel. Do not remove it, and do not let it run after the panel has closed or during collapse.

Status strings, in order: mic denied, `inputProblem` (graph failed to start), **Waiting for the microphone…**, **Slap.**, **Hearing you.**

## What counts as a slap

`ImpactClassifier` is pure and covered by unit tests. Keep it that way. Current feel, stored under `slapThreshold.v2` so the old `0.25` default is not reused:

- threshold `0.06` (slider clamps `0.04...0.45`)
- crest at least `2.5`, or a sharp tick with crest at least `6`
- low-band ratio at least `0.22`, unless the peak is at least `0.12` (a bright side-of-case tick)
- duration `0.008...0.180` seconds, debounce `0.7` seconds

A hit is a sharp tick, a loud impulsive tick, or a bass thump. Speech is too long. The meter draws `peak / 0.3`, so a small real signal is visible. The loudest channel wins; channel 0 on this Mac can be the quiet one.

## Process footgun

`NSApp.delegate` is weak, and `@main` on an `NSApplicationDelegate` does not assign it on this SDK. `SmackToFixMain` creates `AppDelegate`, assigns `app.delegate`, and only then calls `app.run()`. The activation policy is `.accessory`. If the menu bar icon disappears, check the delegate before debugging the status item. The status item shows up as a Control Center window named `com.smacktofix.SmackToFix`, not as a window owned by the app.

## Leave it alone

- No audio files. Buzz and pop are procedural PCM.
- No accelerometer, IOKit smack detection, or App Sandbox.
- No Dock icon, and no color image in the menu bar. `StatusIcon` stays a template.
- Do not commit unless the author asks. Do not force-push.
