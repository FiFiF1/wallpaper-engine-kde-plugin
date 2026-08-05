# Native renderer fixes

Two patches to `catsout/wallpaper-scene-renderer` (the C++ scene renderer built
into `libWallpaperEngineKde.so`). Combined diff: `renderer-fixes.patch`.

## 1. Shader-preprocessor stack overflow (`WPShaderParser.cpp`)

`Preprocessor`'s interface-variable regex ran over the whole preprocessed shader
with a char class `[\s\w]` that matches newlines, so on a large shader
libstdc++'s recursive `std::regex` recursed until the stack overflowed — a hard
plasmashell crash. Fix: `[\s\w]` → `[ \t\w]` (space/tab/word, not newline).
Byte-identical extraction on real single-line GLSL; no runaway recursion.

## 2. `TEXB0004` texture-container parsing (`WPTexImageParser.cpp`)

`.tex` files of version `TEXB0004` store two extra header fields after the image
count — a FreeImage format id (e.g. `PNG=13`, or `-1` for raw) and a flag. The
parser read one field and only for `TEXB0003`, so every `TEXB0004` texture
misaligned: image-container textures (PNGs packed in a `.tex`) read garbage
mipmap sizes and failed to load, raw ones loaded as empty. Symptom: a wallpaper
whose layers are `TEXB0004` PNG containers rendered as **gray + noise**, and the
resulting null textures fed a GPU **`VK_ERROR_DEVICE_LOST`**. Fix: read the
format field for `TEXB0003+`, skip the extra field for `TEXB0004+`, and take the
FreeImage-decode path for `TEXB0003+` (not just `==3`). This fixed the
`直到大地变成一颗酸橙` wallpaper (id 3776778760) — it now renders fully.

## 3. In-scene video textures (`VideoTex.*`, `WPTexImageParser.cpp`)

Some scene wallpapers use a playing **MP4/H.264 video as a layer texture** (the
`.tex` payload is an `ftyp` MP4). The renderer treated the video bytes as raw
pixels → noise. Added an ffmpeg-based decoder (`VideoTex.cpp`) and a branch in the
texture parser that decodes to RGBA. **Now plays continuously**: a threaded
`VideoPlayer` decodes frames off the render thread paced to the stream's frame
rate and loops; the parser keeps the MP4 in `Image::videoData`; `TextureCache`
registers a video texture per such layer and re-uploads the newest frame to it
each rendered frame (`UpdateVideos()`, hooked at the top of
`VulkanRender::drawFrame`). The first decoded frame is still uploaded at load as a
fallback. Adds a build dependency on **ffmpeg** (libavcodec/format/util/swscale).
Cost note: 4K60 layers are software-decoded on CPU (~1.2 cores for a 4K60 clip) and
re-uploaded per frame with a full-device `WaitIdle`; a transfer-queue + fence path
and display-size decode would cut that, left as future work.

## 4. Audio-reactive scenes (`Audio/AudioCapture.*`, `WPShaderValueUpdater.*`)

Wallpaper Engine scenes that enable the `AUDIOPROCESSING` combo sample two
uniforms, `g_AudioSpectrum16Left[16]` / `g_AudioSpectrum16Right[16]`. The
renderer fed neither (no capture, no analysis, not even a zero stub), so those
wallpapers stayed frozen. Added `AudioCapture`: it opens the PulseAudio /
PipeWire **monitor source of the default sink** — matching `"<sink>.monitor"`,
because grabbing merely the first `.monitor` device lands on an idle HDMI port
and captures silence — and reduces it to two 16-band spectra with a radix-2 FFT
(1024-pt, Hann window, log-spaced bands 30Hz-16kHz, dB-mapped to 0..1 with
fast-attack / slow-release smoothing). `WPShaderValueUpdater` detects the
uniforms via `existsOp` and feeds them each frame.

Two deliberate properties:
- **Lazy and shared.** The device opens only when a scene actually samples the
  spectrum, and one capture is shared process-wide (plasmashell runs a scene per
  monitor; one device per scene would mean several recording streams). It is
  released when the last audio-reactive scene goes away.
- **Never fatal.** No audio server, no monitor source, or a failed device all
  degrade to reporting silence rather than failing the wallpaper.

Analysis is cached (recomputed at most every ~8ms), so every node in every scene
can call it per frame cheaply.

## 5. Sound-device teardown race (`Audio/miniaudio-wrapper.hpp`)

`Device::UnInit()` released the channels **before** `ma_device_uninit()`, so the
audio thread could still be inside `NextPcmData` reading a decoder (and the
scene-owned storage behind it) that had just been freed. It showed up as a
**SIGBUS in `WPSoundStream::NextPcmData`** when a scene with sound was torn
down. Fix: uninit the device first — it waits for the in-flight callback — then
unmount the channels. Six consecutive shutdown cycles produce no coredump where
the unfixed build crashed.

Not reported upstream (the repo is archived). Local patches.

## Build / install / revert

Built in the `plasmabuild` fedora-44 toolbox (matches host Qt6 6.11 / KF6 6.28):

```sh
git clone --recursive --depth 1 --shallow-submodules \
    https://github.com/catsout/wallpaper-engine-kde-plugin.git we-build
cd we-build/src/backend_scene && git apply < .../renderer-fixes.patch && cd ../..
# in the plasmabuild toolbox:
sudo dnf install -y extra-cmake-modules kf6-plasma-devel kf6-kpackage-devel \
    qt6-qtdeclarative-devel qt6-qtbase-private-devel lz4-devel vulkan-loader-devel \
    mesa-libGL-devel libglvnd-devel ninja-build glslang-devel mpv-libs-devel mpv-devel ffmpeg-free-devel
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DUSE_PLASMAPKG=OFF -DBUILD_QML=ON
make -j$(nproc)
```

Install (the bundle keeps `libWallpaperEngineKde.so.bak` = original COPR build,
and `.fixed` = this patched build):

```sh
DST=~/.local/lib/wallpaper-engine/qml/com/github/catsout/wallpaperEngineKde
cp build/src/libWallpaperEngineKde.so "$DST/libWallpaperEngineKde.so"
systemctl --user stop plasma-plasmashell && systemctl --user start plasma-plasmashell
```

Revert: `cp "$DST/libWallpaperEngineKde.so.bak" "$DST/libWallpaperEngineKde.so"`
then stop/start plasmashell.

**Note:** `wallpaper-engine-refresh-libs` re-fetches the unpatched COPR `.so` and
overwrites this — rebuild + reinstall after running it.

## Known remaining gaps (non-fatal)

The 3776778760 scene still logs, but renders fine without them: a **video
effect** whose shader won't compile (`'[]' : scalar integer expression`), and
**shadow-atlas / light-cookie** render targets the renderer doesn't implement.
