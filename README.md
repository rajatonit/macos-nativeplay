# macos-nativeplay

PS5 Remote Play as a native Mac app (**PS5Stream.app**). The PS5's 1080p60 HEVC stream is decoded in hardware, cleaned of compression artifacts, upscaled to the display's native resolution with a neural network, and shown in HDR on an XDR display. On a 120 Hz screen it can also generate frames up to 120 fps.

The connection and pairing use the library from [chiaki-ng](https://github.com/chiaki-ng/chiaki-ng) (a git submodule in `vendor/chiaki-ng`). The video, audio, input, controller feedback and rendering code is in `Sources/PS5Stream`.

> Not affiliated with or endorsed by Sony Interactive Entertainment. "PlayStation" and "PS5" are trademarks of Sony Interactive Entertainment Inc.

- [Requirements](#requirements)
- [Install](#install)
- [Set up the PS5 and pair it](#set-up-the-ps5-and-pair-it)
- [First launch](#first-launch)
- [Using it](#using-it)
- [Troubleshooting](#troubleshooting)
- [Build from source](#build-from-source)
- [Releasing a new version](#releasing-a-new-version)
- [License](#license)

## Requirements

**Every Mac needs:**

- **An Apple Silicon Mac** (M1 or later). Intel Macs aren't supported.
- **macOS 26 (Tahoe) or later.**
- **A PS5 on the same local network**, with Remote Play turned on. Only a standard PS5 has been tested.
- **chiaki-ng**, used once to pair the console (see below).

**What each Mac can run**

The stream is always 1080p60; the PS5 refuses higher resolutions for Remote Play. What changes from Mac to Mac is how much GPU work you can afford to make it look better. At 60 fps there are 16.7 ms per frame, and below ~10 ms of GPU work the Mac stays cool and quiet.

Only the M5 Pro has been measured. The M5 family has neural accelerators in the GPU, which run the upscaling network faster than earlier chips. Figures for other Macs are estimates scaled by GPU size; the window title shows the real number for your Mac, so check it.

| Mac | Suggested settings | Notes |
|---|---|---|
| M5 Pro / M5 Max | Anything, including **Max** (120 fps frame generation + Neural HQ) | Measured on a 14" M5 Pro: Balanced ~5.5 ms, Cool ~3 ms of GPU work per frame. |
| M5, M4 Pro / Max, M3 Max, M2 Max, M1 Max | **Balanced** (Neural HQ, 60 fps). Max may work on Max-class chips. | Frame generation costs ~10 ms per PS5 frame for a 60 fps game and ~26 ms per game frame for a 30 fps game (3 in-betweens) on an M5 Pro, so it's tight below that. |
| M4, M3 Pro, M2 Pro, M1 Pro | **Cool** (Neural fast) or upscaler **MetalFX**; try Neural HQ and watch the GPU ms | Neural HQ is roughly 10–15 ms here, which leaves little headroom. |
| M1, M2, M3 (base) | **Cool** with upscaler **MetalFX** or **Neural fast** | Clean-up (~0.5 ms) and highlight boost are cheap and fine on every Mac. |

**Display**

- **HDR and highlight boost** need an HDR display: the XDR screen on a 14"/16" MacBook Pro (M1 Pro and later), a Pro Display XDR, or another HDR monitor. On other screens, macOS tone-maps the HDR stream to SDR. You can also ask for SDR with `--sdr`.
- **120 fps frame generation** only helps on a 120 Hz display: a 14"/16" MacBook Pro with ProMotion, or a 120 Hz external monitor. It adds about one frame of input lag.

**Network**

- Connect the PS5 with **Ethernet** if you can. Put the Mac on **5 GHz or 6 GHz Wi-Fi** (Wi-Fi 6/6E/7) close to the router, or use Ethernet.
- The default bitrate is 30 Mbit/s. If the picture stutters or breaks up, lower it with `--bitrate 20000`.

**Controller**

- **DualSense, connected by USB**, gets rumble, adaptive triggers, lightbar and player LEDs, touchpad and motion. Bluetooth works for buttons; feedback is only tested over USB.
- Without a controller you can use the keyboard (see [Keys](#keys)).

## Install

1. Download the latest `macos-nativeplay-<version>.zip` from [Releases](https://github.com/rajatonit/macos-nativeplay/releases) and unzip it.
2. Move **PS5Stream.app** to **Applications**.
3. The app isn't notarised by Apple, so macOS blocks it the first time. Clear the download flag once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/PS5Stream.app
   ```

   You can also open it, click **Done** on the warning, then go to **System Settings > Privacy & Security** and click **Open Anyway**.

Each release also has a `.sha256` file if you want to check the download (`shasum -a 256 -c macos-nativeplay-<version>.zip.sha256`).

## Set up the PS5 and pair it

You only do this once.

**On the PS5:**

1. **Settings > System > Remote Play** → turn on **Enable Remote Play**.
2. To let the Mac wake the PS5 from rest mode: **Settings > System > Power Saving > Features Available in Rest Mode** → turn on **Stay Connected to the Internet** and **Enable Turning On PS5 from Network**.
3. Note the PS5's IP address: **Settings > Network > Connection Status > View Connection Status** → **IPv4 Address**. It's best to give the PS5 a fixed address (DHCP reservation) in your router, so it doesn't change.

**Pair with chiaki-ng** (PS5Stream reads the pairing chiaki-ng saves):

1. Install chiaki-ng from its [releases page](https://github.com/chiaki-ng/chiaki-ng/releases).
2. Open chiaki-ng. Your PS5 should appear; if it doesn't, add it with its IP address.
   **Write down the IP address chiaki-ng shows under your PS5's name.** PS5Stream asks for it on first launch.
3. Choose to register the console. chiaki-ng asks for your PSN account ID (it can look it up for you when you sign in to PSN) and a PIN.
4. On the PS5, go to **Settings > System > Remote Play > Link Device** to get the 8-digit PIN, and enter it in chiaki-ng.
5. Optional: if your PS5 profile has a login passcode, save it in chiaki-ng's console settings, so PS5Stream can sign in without asking.

You can close chiaki-ng after pairing. It doesn't need to run alongside PS5Stream.

## First launch

1. Open **PS5Stream** and enter the PS5's IP address when asked: the one chiaki-ng shows for your console (or the one from the PS5's network settings). It's remembered for next time.
2. When macOS asks to **find devices on your local network**, click **Allow**. Without this the app can't reach the PS5.
3. If the PS5 is in rest mode, it wakes up. If your profile has a passcode and chiaki-ng doesn't have it saved, the app asks for it.
4. The game appears. Press **S** to open the settings panel.

To connect to a different PS5 address later, run:

```bash
open -a PS5Stream --args --host 10.0.0.42
```

## Using it

### Settings panel

Press **S** (or **⌘,**, or choose **Show/Hide Settings** from the menu bar) to show or hide the panel over the video. Every option can be changed there with a click, and the panel shows what's actually running. In full screen the pointer stays visible while the panel is open. After a click, keys go straight back to the game.

| Setting | What it does |
|---|---|
| **Power** | **Cool**: Neural fast at 60 fps, the least GPU work. **Balanced** (default): Neural HQ at 60 fps. **Max**: Neural HQ plus 120 fps frame generation. The app steps down by itself when the Mac gets hot, and uses Cool on battery or in Low Power Mode; plugging the charger back in restores your choice. |
| **Upscaler** | How the 1080p stream is enlarged to the screen. **Neural HQ** and **Neural fast** run the FSRCNNX neural network on the GPU (the sharpest results). **MetalFX** is Apple's spatial upscaler. **Bilinear** is plain resizing, the cheapest. |
| **120 fps frame generation** | Apple's machine-learning frame interpolation fills in frames up to 120 fps. The app works out the game's real frame rate: a 60 fps game gets 1 generated frame between each pair, and a 30 fps game (which the PS5 streams at 60 by sending each picture twice) gets its repeats dropped and 3 generated frames between each pair, so motion is smooth instead of judder-stepping. Only runs in Max. Adds about one game frame of input lag (more at 30 fps). This is interpolation of the video, not in-game frame generation like DLSS or XeSS, which need the game's own motion data. |
| **HDR highlight boost** | The PS5 masters highlights for around 400 nits; this stretches everything above 200 nits up to the XDR panel's 1000. Mid-tones and skin don't change. |
| **FPS counter** | Shows frames on screen, the game's real frame rate, how many frames were generated, the upscaler and GPU time in the top-right corner of the picture. |
| **Artifact clean-up** | Smooths the banding and blocky steps that compression leaves in sky, fog and dark areas, before upscaling. Edges and texture are left as decoded. About 0.2 ms per frame. |
| **Microphone** | Sends the Mac's microphone to the PS5 for party and game chat. Starts muted. |

All settings except the microphone are remembered between launches.

### Keys

| Key | Action |
|---|---|
| `S` / `⌘,` | Show or hide the settings panel |
| `E` | Cycle power mode (Cool → Balanced → Max) |
| `U` | Cycle upscaler |
| `I` | Toggle 120 fps frame generation |
| `H` | Toggle HDR highlight boost |
| `D` | Toggle artifact clean-up |
| `C` | Split screen: standard picture on the left, enhanced on the right |
| `F` | On-screen fps counter |
| `R` | Start or stop recording the picture to `~/Movies` |
| `M` | Toggle microphone |
| `⌃⌘F` | Full screen |
| `⌘Q` | Quit (asks whether to put the PS5 in rest mode) |

Without a controller: arrow keys are the d-pad, `Return` is Cross, `Esc` is Circle, `P` is the PS button, `O` is Options and `T` is the touchpad click.

### Other features

- **Wake and rest.** The app wakes the PS5 from rest mode before connecting. On quit it offers **Rest Mode**, **Leave On** or **Cancel**, with a "Remember my choice" box. To be asked again: `defaults delete local.ps5stream.player quitAction`.
- **PS button.** The DualSense PS button opens the PS5's menu, not Launchpad or Apple Arcade.
- **PS5 keyboard.** When the PS5 asks for text, a Mac text box opens.
- **Busy console.** If the PS5 is still closing a previous session, the app retries automatically.
- **Mouse pointer.** It's hidden over the video in full screen.

### Window title

The title bar shows live stats: power mode, upscaler, HDR/SDR, `clean` when clean-up is on, resolution, frames received and shown per second, **GPU ms per frame**, network bitrate, lost frames, decode time and the stream's peak brightness. If the GPU ms is often above ~12, pick a lighter power mode or upscaler.

### Command-line options

Pass options with `open -a PS5Stream --args <options>`, or run `/Applications/PS5Stream.app/Contents/MacOS/PS5Stream <options>` to see the log in Terminal.

| Option | Meaning |
|---|---|
| `--host <address>` | PS5 IP address (remembered) |
| `--sdr` | Ask for SDR instead of HDR. HDR is the default; the PS5 sends it even when its own TV is SDR. |
| `--bitrate <kbps>` | Stream bitrate, default `30000` |
| `--resolution 1080\|1440\|2160` | Ask for a higher stream resolution. Standard PS5s refuse anything above 1080. |
| `--on-quit ask\|rest\|keep` | What happens to the PS5 when you quit |
| `--verbose` | Print chiaki's log and pipeline counters |
| `--file clip.mov` | Play a local video through the renderer, without a console |
| `--compare` | Start in split-screen compare mode |
| `--fps` | Start with the on-screen fps counter |
| `--record` | Start recording as soon as the picture appears |

### Recording a demo clip

Recording saves what the app actually renders: full resolution, at the frame rate on screen (up to 120 fps), with no Screen Recording permission needed. HDR is converted to SDR so the clip looks right everywhere. A `.stats.txt` file with the per-second fps and GPU numbers is saved next to the video.

1. Press **F** for the on-screen fps counter. It's drawn into the picture, so it shows in full screen and in recordings. With frame generation on it reads like `120 fps on screen · game 30 fps · 90 generated · Neural HQ · 4.5 ms GPU + 26.2 ms frame gen`, so it's clear how many frames the game itself rendered.
2. Press **C** for the split screen (plain scaling on the left, the full pipeline on the right). It's most convincing with fine detail: foliage, fences, signs, distant buildings.
3. Press **R** to start recording, play for 20–30 seconds, then press **R** again.
4. Make a captioned 1080p clip from it:

   ```bash
   swift Tools/make-demo.swift ~/Movies/"PS5Stream 2026-11-22 at 21.30.00.mp4" --start 5 --duration 20
   ```

   It adds a title, labels for the two halves, and a link to this project at the end. If the fps counter wasn't on, it also captions each second with the measured mode, fps and GPU time (`--captions` forces these on). Change the text with `--title` and `--link`. The result is saved next to the recording as `… demo.mp4`.

Most video sites and players show 60 fps at most, so a 120 fps clip plays at 60 there. The caption still shows the real on-screen rate.

## Troubleshooting

The log is at `~/Library/Logs/PS5Stream.log` when the app is opened from Finder. It prints a stats line every second.

| Problem | Fix |
|---|---|
| "No route to host", or it never connects | Local Network permission is off. Turn on PS5Stream in **System Settings > Privacy & Security > Local Network**. Also check the IP address hasn't changed. |
| "No paired console found" | Pair the PS5 in chiaki-ng first (see above). |
| "Remote Play is already in use" | Another device is streaming, or the PS5 is still closing the last session. The app retries; otherwise close the other session. |
| It doesn't wake from rest mode | Turn on the two rest-mode network options on the PS5 (see setup). |
| Stutter or blocky picture | Use Ethernet for the PS5, move the Mac closer to the router, or lower `--bitrate`. The `lost` count in the title shows network loss. |
| Mac gets hot or loud | Pick **Cool** in the settings panel, or switch the upscaler to MetalFX. |
| macOS says the app is damaged or can't be opened | Run the `xattr` command from [Install](#install). |
| The PS button opens Launchpad | Check the controller is a DualSense. In **System Settings > Game Controllers**, turn off the Home button shortcut. |

## Build from source

You need Xcode 26 or later, [Homebrew](https://brew.sh) and Python 3.

```bash
git clone https://github.com/rajatonit/macos-nativeplay.git
cd macos-nativeplay
Tools/build-chiaki.sh --deps
Tools/make-app.sh
open build/PS5Stream.app
```

- `Tools/build-chiaki.sh --deps` installs the Homebrew packages, fetches the chiaki-ng submodule and builds `libchiaki`. Run it again only when the submodule changes; leave out `--deps` once the packages are installed.
- `Tools/make-app.sh` builds the app and wraps it in `build/PS5Stream.app`. Homebrew libraries are linked statically, so the app runs on Macs without Homebrew.
- If you have an Apple Development certificate, the script signs with it. The signature then stays the same across rebuilds, so macOS remembers the Local Network and microphone permissions. Otherwise it signs ad hoc.

To test the renderer without a console:

```bash
swift Tools/make-sample.swift samples/test-1080p.mov
open build/PS5Stream.app --args --file samples/test-1080p.mov
```

**Source layout:**

| File | Role |
|---|---|
| `StreamClient.swift` | Session, wake and rest, audio and video callbacks (libchiaki) |
| `HEVCDecoder.swift` | VideoToolbox hardware decode, HDR peak measurement |
| `Renderer.swift` | Metal rendering, colour conversion, highlight boost, power modes |
| `ArtifactCleaner.swift` | Deband and deblock pass before upscaling |
| `NeuralUpscaler.swift`, `FSRCNNX*.swift` | FSRCNNX 2x network; the HQ path uses Metal 4 tensor ops (generated by `Tools/gen-fsrcnnx.py`) |
| `FrameInterpolator.swift` | 60 → 120 or 30 → 120 fps with VideoToolbox frame interpolation |
| `FrameCadence.swift` | Detects the game's real frame rate (30 fps games arrive as repeated frames in the 60 fps stream) |
| `SettingsPanel.swift` | On-screen settings panel |
| `Recorder.swift` | Recording to `~/Movies` (R) |
| `FPSOverlay.swift` | On-screen fps counter (F) |
| `Input.swift`, `DualSenseFeedback.swift` | Controller input, PS button, haptics, triggers, lightbar |
| `PowerSource.swift` | Battery and charger detection |

## Releasing a new version

GitHub Actions (`.github/workflows/build.yml`) builds the app on a macOS 26 runner for every push to `main` and every pull request. The zipped app is attached to each run as an artifact.

To publish a release, tag a commit with a version and push the tag:

```bash
git tag v1.1.0
git push origin v1.1.0
```

The workflow builds the app with that version number, zips it as `macos-nativeplay-1.1.0.zip` with a SHA-256 checksum, and creates a GitHub Release with install notes and the changes since the last tag.

## License

AGPL-3.0 (with the OpenSSL linking exception), the same as chiaki-ng, whose library this app links. See [LICENSE](LICENSE). The FSRCNNX network weights are by igv and licensed LGPL-3.0.
