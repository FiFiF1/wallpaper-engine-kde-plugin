# Native renderer fix — shader-preprocessor stack overflow

Some Wallpaper Engine **scene** wallpapers hard-crash plasmashell inside the
native library `libWallpaperEngineKde.so`. Root cause: in
`catsout/wallpaper-scene-renderer` `src/WPShaderParser.cpp`, function
`Preprocessor`, the interface-variable regex

```cpp
std::regex re_io(R"(.+\s(in|out)\s[\s\w]+\s(\w+)\s*;)", std::regex::ECMAScript);
```

is run with `sregex_iterator` over the **whole** glslang-preprocessed shader. The
char class `[\s\w]` includes `\n`, so on a large shader the greedy quantifier
spans the entire file and libstdc++'s recursive `std::regex` recurses until the
stack overflows → SIGSEGV/SIGABRT, taking the whole desktop down.

## The fix (`WPShaderParser-io-regex.patch`)

Change the char class `[\s\w]` → `[ \t\w]` (space/tab/word, **not** newline).
GLSL interface declarations are single-line, so this is byte-for-byte identical
extraction on real shaders (verified by comparing the old and new regex output on
the crashing scene's shaders and on realistic/contrived inputs), while making the
newline-spanning — and thus the runaway recursion — impossible. One line changed.

Reported upstream: no (the repo is archived). This is a local patch.

## Rebuilding the native library

The shipped `.so` is a prebuilt COPR RPM (see `~/.local/bin/wallpaper-engine-refresh-libs`),
so the fix has to be compiled and the `.so` swapped into the user-local bundle.
Built in the `plasmabuild` fedora-44 toolbox (matches the host Qt6/KF6 ABI):

```sh
git clone --recursive --depth 1 --shallow-submodules \
    https://github.com/catsout/wallpaper-engine-kde-plugin.git we-build
cd we-build/src/backend_scene && git apply < .../WPShaderParser-io-regex.patch && cd ../..
# in the plasmabuild toolbox:
sudo dnf install -y extra-cmake-modules kf6-plasma-devel kf6-kpackage-devel \
    qt6-qtdeclarative-devel qt6-qtbase-private-devel lz4-devel vulkan-loader-devel \
    mesa-libGL-devel libglvnd-devel ninja-build glslang-devel mpv-libs-devel mpv-devel
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DUSE_PLASMAPKG=OFF -DBUILD_QML=ON
make -j$(nproc)
```

Install the result (back up the original first):

```sh
DST=~/.local/lib/wallpaper-engine/qml/com/github/catsout/wallpaperEngineKde
cp "$DST/libWallpaperEngineKde.so" "$DST/libWallpaperEngineKde.so.bak"
cp build/bin/.../libWallpaperEngineKde.so "$DST/libWallpaperEngineKde.so"
systemctl --user stop plasma-plasmashell && systemctl --user start plasma-plasmashell
```

## Revert

```sh
cp "$DST/libWallpaperEngineKde.so.bak" "$DST/libWallpaperEngineKde.so"
systemctl --user stop plasma-plasmashell && systemctl --user start plasma-plasmashell
```

**Note:** `wallpaper-engine-refresh-libs` re-fetches the COPR `.so` and will
overwrite this patched build. Re-apply after running it.
