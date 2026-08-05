# Wallpaper Engine KDE plugin — enhanced fork

A fork of **[catsout/wallpaper-engine-kde-plugin](https://github.com/catsout/wallpaper-engine-kde-plugin)**
(GPLv2+, by **catsout**) that renders Steam **Wallpaper Engine** wallpapers on KDE
Plasma. The upstream project is archived; this fork adds crash fixes, a bug fix
that makes many previously-broken scene wallpapers render, a reworked picker/
Workshop UI, in-place subscribe/unsubscribe, and a self-healing crash guard.

> This repository is the **QML + Python half** of the plugin (the picker UI and
> file backend). The **native renderer** (`libWallpaperEngineKde.so`) is built
> from catsout's [`wallpaper-scene-renderer`](https://github.com/catsout/wallpaper-scene-renderer);
> the two renderer bug fixes below are provided as a patch in
> [`_native-fix/`](_native-fix/) — you rebuild that library and swap it in.

## What this fork adds over upstream

**Native renderer fixes** (`_native-fix/renderer-fixes.patch`, applied to
`wallpaper-scene-renderer`, rebuild required):

- **Shader-preprocessor stack overflow → hard desktop crash.** An interface-variable
  regex spanned the whole preprocessed shader and recursed until libstdc++'s
  `std::regex` blew the stack, taking plasmashell down on certain scenes. One-line
  char-class fix.
- **`TEXB0004` texture-container parsing.** `.tex` v4 files store two extra header
  fields the parser only read for `TEXB0003`, so *every* `TEXB0004` texture
  misaligned — PNG-in-`.tex` containers failed and the wallpaper rendered as gray
  noise (and fed a GPU `VK_ERROR_DEVICE_LOST`). Fixed; those wallpapers now render.

**Picker / Workshop UI (QML):**

- Native in-dialog **Workshop browser** (search, filters, sort, paging) — no
  embedded WebEngine, so it can't take the shell down.
- **Subscribe / unsubscribe in place** and a **download progress** indicator, by
  reusing the running Steam client's cached web session (see note below).
- **Per-wallpaper settings** show only controls the selected wallpaper actually
  uses (a silent video has no volume slider, etc.).
- Cross-monitor apply, a monitor picker that mirrors your real layout, a translate
  button for Chinese/Japanese/Russian titles & descriptions, and a bounded/scrolling
  Workshop detail popup.

**Self-heal (`_crashguard/`):** a small user service that, if a wallpaper still
manages to crash-loop plasmashell, disables only the offending scene (showing an
error card on that monitor), logs it, and restarts the shell — widening to all
scenes only after repeated failures.

## Steam session note (transparency)

The in-place subscribe/unsubscribe feature reads your **local** Steam client's
web-session cookie (`steamLoginSecure`) from its browser cache to call Steam's
subscribe API without opening a browser. It only ever touches **your own** local
session on **your** machine, the token is used for one request and never stored or
logged, and if it isn't available the buttons simply fall back to opening the item
in Steam. The code is in [`contents/pyext.py`](contents/pyext.py) (`steam_*`). If
you don't want it, don't use those buttons — nothing reads the session otherwise.

## Install (QML half)

```sh
git clone https://github.com/FiFiF1/<repo>.git \
    ~/.local/share/plasma/wallpapers/com.github.catsout.wallpaperEngineKde
```

You still need catsout's **native module + libmpv** (from your distro package or
the [Fedora COPR](https://copr.fedorainfracloud.org/coprs/kylegospo/wallpaper-engine-kde-plugin/)),
and Wallpaper Engine installed via Steam for the wallpaper assets. To get the
renderer bug fixes, rebuild the native library with `_native-fix/renderer-fixes.patch`
(build steps in [`_native-fix/README.md`](_native-fix/README.md)) and swap in the
resulting `libWallpaperEngineKde.so`.

Then, in **System Settings → Wallpaper**, choose *Wallpaper Engine*.

## Known limitations (unimplemented engine features)

Inherited from upstream — the plugin is a partial reimplementation, not all of
Wallpaper Engine. Scenes using these still load, just without the effect (or, for
video textures, may need reverting):

- **In-scene video / animated textures** — some scene wallpapers embed MP4 video as
  a layer texture (often "4k/60fps" ones); the scene renderer doesn't decode video
  textures, so those layers show noise. (Standalone *video-type* wallpapers work
  fine via the mpv backend — this gap is only videos used *inside* a scene.)
- **Audio-reactive shaders** (`g_AudioSpectrum*`) — no audio FFT is fed to shaders.
- **Shadow atlas / dynamic 2D lighting / light cookies** — not implemented.
- Some custom effect shaders relying on WE-specific HLSL semantics may not compile.

## Credits & license

Original plugin and native renderer © **catsout** and contributors, GPLv2+.
This fork keeps that license (GPLv2+) — see [`LICENSE`](LICENSE). Wallpaper Engine
is a product of Wallpaper Engine Team / Kristjan Skutta; this project is unaffiliated.
