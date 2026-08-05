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
texture parser that decodes a frame to RGBA. **Currently the first frame only**
(static) — the content is correct instead of noise; continuous 60fps playback is
not yet wired (it needs a streaming decoder + updatable texture + render-loop
hook). Adds a build dependency on **ffmpeg** (libavcodec/format/util/swscale).

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
