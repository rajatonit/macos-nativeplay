# PS5Stream

PS5 Remote Play on the Mac. The PS5's 1080p60 HEVC stream is hardware-decoded, then upscaled on the GPU to the display's native resolution with a neural network (FSRCNNX) or MetalFX. HDR is shown on the XDR panel as BT.2100 PQ.

The connection and pairing use chiaki-ng's library (`vendor/chiaki-ng`). The video, audio, input, controller feedback and rendering code is in `Sources/PS5Stream`.

## Build and open

Pair the PS5 in chiaki-ng first; the app reads that pairing from chiaki-ng's preferences.

```bash
Tools/make-app.sh
open build/PS5Stream.app --args --host 192.168.1.20
```

After the first run the app remembers the address, so you can open `build/PS5Stream.app` from Finder. On first launch, allow Local Network access, or the app can't reach the PS5.

The script signs the app with your Apple Development certificate if you have one. That keeps the signature stable, so macOS remembers the Local Network and microphone permissions across rebuilds.

Options:

- `--sdr` requests the SDR stream. HDR is the default: the PS5 sends HDR when asked, even when its own TV is SDR.
- `--bitrate 20000` sets the bitrate in kbps (default 30000).
- `--resolution 1440` or `--resolution 2160` asks the PS5 for a higher stream resolution (default 1080). The PS5 may answer with a lower one; the window title shows what actually arrives.
- `--on-quit ask|rest|keep` sets what happens to the PS5 when you quit. The default asks.
- `--verbose` prints chiaki's log and pipeline counters.
- `--file clip.mov` tests the renderer on a local video without the console.

## What it does

- **Wake and rest.** If the PS5 is in rest mode, the app wakes it before connecting. On quit, it offers Rest Mode, Leave On or Cancel, with a "Remember my choice" box. To be asked again after remembering, run `defaults delete local.ps5stream.player quitAction`.
- **Login passcode.** If your PS5 profile has a passcode, the PS5 asks for it after waking from rest. The app uses the passcode saved in chiaki-ng if there is one; otherwise it asks you.
- **HDR.** The window title shows the measured peak brightness of the stream.
- **DualSense.** Rumble, adaptive triggers, lightbar and player LEDs are sent to the controller directly over HID, using the PS5's own trigger data. The touchpad (two fingers and click) and motion sensors are sent to the PS5. The PS5's detailed haptics are approximated as rumble.
- **Microphone.** `M` toggles the Mac's microphone for party and game chat. It starts muted.
- **PS5 keyboard.** When the PS5 asks for text, a Mac text box opens.
- **Busy console.** If the PS5 is still closing the previous session, the app retries automatically.

Keys:

- `U` cycles the upscaler: Neural HQ (default), Neural fast, MetalFX, bilinear. The neural modes run the FSRCNNX network from chiaki-ng on the GPU.
- The mouse pointer is hidden over the video in full screen.
- `E` cycles the power mode: Max (120 fps + Neural HQ, ~65% GPU), Balanced (Neural HQ at 60 fps, ~50%, default), Cool (Neural fast at 60 fps, ~20%). Remembered. The app steps down by itself when macOS reports the Mac is hot, and uses Cool in Low Power Mode.
- `I` toggles 120 fps (only used in Max): Apple's machine-learning frame interpolation adds a generated frame between each pair from the PS5 (macOS 26+, on by default, remembered). It adds roughly one frame of input lag. With Neural HQ, real PS5 frames still get HQ and the generated in-between frames get Neural fast.
- `H` toggles the HDR highlight boost (stretches highlights above 200 nits up to 1000).
- `M` toggles the microphone.
- `Cmd-Ctrl-F` switches to full screen.
- `Cmd-Q` quits.
- Without a controller, the arrow keys are the d-pad, `Return` is cross, `Esc` is circle, `P` is the PS button, `O` is options and `T` is the touchpad click.

## Rebuild the chiaki library

You only need to do this after a fresh clone.

```bash
brew install cmake protobuf opus json-c miniupnpc libevent openssl@3 pkgconf
python3 -m venv vendor/.venv && vendor/.venv/bin/pip install grpcio-tools
git clone --depth 1 --branch v1.10.1 --recurse-submodules --shallow-submodules https://github.com/chiaki-ng/chiaki-ng.git vendor/chiaki-ng
cmake -S vendor/chiaki-ng -B vendor/chiaki-ng/build -DCMAKE_BUILD_TYPE=Release \
  -DCHIAKI_ENABLE_TESTS=OFF -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_GUI=OFF \
  -DCHIAKI_ENABLE_SETSU=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF -DCHIAKI_ENABLE_SPEEX=OFF \
  -DCHIAKI_ENABLE_RUDP=OFF -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF -DCHIAKI_ENABLE_PI_DECODER=OFF \
  -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF -DOPENSSL_ROOT_DIR=$(brew --prefix openssl@3) \
  -DPYTHON_EXECUTABLE=$PWD/vendor/.venv/bin/python
cmake --build vendor/chiaki-ng/build -j 12
```

## Test clip

```bash
swift Tools/make-sample.swift samples/test-1080p.mov
```
