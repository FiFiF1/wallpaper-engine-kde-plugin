# Native renderer fixes

Patches to the two repos that build `libWallpaperEngineKde.so`:
- `renderer-fixes.patch` — `catsout/wallpaper-scene-renderer`, the scene
  renderer submodule (`we-build/src/backend_scene`). Fixes 1-6 below.
- `plugin-fixes.patch` — the outer plugin repo itself
  (`catsout/wallpaper-engine-kde-plugin`, `we-build/src/`: `plugin.cpp`,
  `CMakeLists.txt`, `qmldir`, and new `WebAudioSpectrum.*`). Fix 7 below.

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

## 5. Sound-device teardown ordering (`Audio/miniaudio-wrapper.hpp`)

`Device::UnInit()` released the channels **before** `ma_device_uninit()`, so in
principle the audio thread could still be inside `NextPcmData` reading a decoder
that had just been freed. Reordered to uninit the device first (it waits for the
in-flight callback), then unmount the channels.

**Honesty note on the evidence.** This started from a `SIGBUS` seen in
`WPSoundStream::NextPcmData`, which looked like that race. It was not: the real
cause was installing a new `libWallpaperEngineKde.so` with `cp` **over the file
while plasmashell had it mmap'd** — overwriting a file-backed mapping in place
invalidates the running process's pages and raises SIGBUS in whatever function
happens to execute next. A later crash under the same procedure landed in
`TextureCache`/`TextureKey::HashValue`, an unrelated function, which is what gave
it away. So this reordering is **defensive hygiene, not a fix for an observed
bug** — no known crash is attributable to the old order.

**Install correctly:** stop plasmashell, replace the `.so`, then start it — or
write alongside and `mv` (an atomic rename swaps the directory entry and leaves
the old inode intact for the running process). Never `cp` over the live library.

## 6. Lighting: `g_LightsColorRadius`, skylight, shadow atlas, light cookies

Four gaps in the lighting path:

- **`g_LightsColorRadius[4]`** (`vec4` per light: `.rgb` colour, `.w` radius) is
  read by the model lighting shaders (`generic.frag`, `generic2.frag`) and was
  fed by nothing. Now filled per frame alongside `g_LightsPosition` /
  `g_LightsColorPremultiplied`.
- **`g_LightSkylightColor`** was parsed into the scene (`general.skylightcolor`)
  but never handed to shaders. Now set next to `g_LightAmbientColor`.
- **`_alias_lightCookie`** — `_alias_` names are engine-provided textures, not
  files. The renderer looked it up in the VFS and logged
  `not found "/assets/materials/_alias_lightCookie.tex"` on every scene load.
  A light with no cookie must sample as white (unmodulated), so the alias now
  resolves to the real `util/white` asset and stays on the normal texture path.
- **`_rt_shadowAtlas`** hit the `unknown tex` / `not found in render targets`
  error paths. It is now recognised and its render target is created **on
  demand**, so only scenes that actually enable `LIGHTS_SHADOW_MAPPING` pay the
  VRAM.

**Scope, stated plainly:** this makes the lighting *inputs* correct and the two
resources resolve. It is **not** shadow casting — nothing renders depth into the
atlas, so it reads as unoccluded and lit geometry simply has no shadows. Real
shadow mapping needs per-light depth passes driven by atlas-transform and
light-projection values that WE passes as *function arguments*
(`PerformShadowMapping(projectedCoords, atlasTransform)`); no shader in the
installed asset set declares a uniform carrying them, so the contract cannot be
observed from this machine, and inventing one would be guesswork. Of 256
installed wallpapers, none enable `LIGHTS_SHADOW_MAPPING` or `LIGHTS_COOKIE`.

Result: scene loads are now free of renderer errors.

## 7. Web-wallpaper audio-reactive visualizers never reacted (`WebAudioSpectrum.*`, `plugin.cpp`, `QtWebView.qml`)

Web wallpapers (QtWebEngine pages) get an audio hookup via
`window.wallpaperRegisterAudioListener(listener)`, which QML wires to
`wpeQml.sigAudio.connect(listener)` (`contents/ui/backend/QtWebView.qml`,
plasma package side). **`sigAudio` was declared and consumed but never
emitted from anywhere in the codebase** — confirmed by grep, zero emit sites.
Every audio-reactive web wallpaper (e.g. "Simplistic Audio Visualizer",
workshop id 923576681) therefore sat permanently idle no matter what was
playing — not "quiet by design", genuinely dead regardless of audio, verified
by playing a tone directly at it before and after this fix.

This is a *different* gap from fix 4 (`g_AudioSpectrum16Left/Right`): that one
only reaches scene wallpapers' native Vulkan shaders. Web wallpapers run in
QtWebEngine, a separate process/backend with no route to those uniforms.

Fix: exposed the same underlying `AudioCapture` (fix 4) to QML as a new native
type, `WebAudioSpectrum`, registered in the `com.github.catsout.wallpaperEngineKde`
QML module (`plugin.cpp`). Since the web-wallpaper JS convention expects a
wider array than the 16-band scene uniforms (verified against 923576681's
`main.js`, which reads `audioArray[0..63]`), `AudioCapture` gained a second,
independently-cached spectrum method (`GetSpectrumWide`, 64 log-spaced bands,
sharing the FFT but not the smoothing state or cache timing with the 16-band
path). A new `WebAudioBridge.qml` (its own file, not inlined into
`QtWebView.qml`) instantiates `WebAudioSpectrum` and polls it on a 50ms Timer,
calling `sigAudio(spectrum())`.

**Loaded by file path (`Loader { source: "WebAudioBridge.qml" }`), not a
top-level `import` in `QtWebView.qml` itself** — matching the exact pattern
`main.qml` already uses for `backend/Scene.qml` (`hasLib`-gated). A bare
top-level import would make *every* web wallpaper hard-depend on the native
library bundle being installed, which currently only scene wallpapers do (the
native bundle is a separate, sometimes-missing install — see
`wekde-crashguard-self-heal` memory on Bazzite rebases deleting it). A Loader
whose source fails to resolve reports `Loader.Error` without breaking the
parent document, so a missing bundle now degrades to "no reactive audio", not
"web wallpapers stop working".

Verified live end-to-end on 923576681: silent baseline reads solid black
(intentional — the wallpaper author set a black canvas background); playing a
two-tone test signal produces the visualizer's actual bar rendering
immediately, distinctly clustered at the two tones' frequencies; returns to
the identical black baseline once audio stops. No coredumps across install +
test cycles.

Not reported upstream (the repo is archived). Local patches.

## Build / install / revert

Built in the `plasmabuild` fedora-44 toolbox (matches host Qt6 6.11 / KF6 6.28):

```sh
git clone --recursive --depth 1 --shallow-submodules \
    https://github.com/catsout/wallpaper-engine-kde-plugin.git we-build
cd we-build/src/backend_scene && git apply < .../renderer-fixes.patch && cd ../..
git apply < .../plugin-fixes.patch    # from we-build/ - touches src/ directly
cd ..
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
# NEVER cp over the live .so: plasmashell has it mmap'd and overwriting it in
# place invalidates the running process's pages -> SIGBUS. Stage + atomic mv.
cp build/src/libWallpaperEngineKde.so "$DST/.new.so"
systemctl --user stop plasma-plasmashell
mv "$DST/.new.so" "$DST/libWallpaperEngineKde.so"
systemctl --user start plasma-plasmashell
```

Revert: `cp "$DST/libWallpaperEngineKde.so.bak" "$DST/libWallpaperEngineKde.so"`
then stop/start plasmashell.

**Note:** `wallpaper-engine-refresh-libs` re-fetches the unpatched COPR `.so` and
overwrites this — rebuild + reinstall after running it.

## 8. Effect-owned render targets logged as "unknown tex" (`WPSceneParser.cpp`)

Effects (Bloom, depth-of-field/"Bokeh blur", Cutout Vignette, and the
"compose" image option) declare their own render targets with an
author-chosen label plus a runtime-unique suffix —
`_rt_<label>_<pointer-address>`, e.g. `_rt_coc_140567771445120` or
`_rt_buffer1_<addr>` (`getAddr()`/`rtname`, same file). There is no fixed
vocabulary of labels to whitelist: by the time `ParseSpecTexName` ran, that
effect-fbo parsing had *already* registered the name into
`pScene->renderTargets` with correct dimensions (`WPSceneParser.cpp:779-848`),
but `ParseSpecTexName`'s dispatch was a hardcoded prefix whitelist with no
branch for these, so every one hit the catch-all `LOG_ERROR("unknown tex
...")` — pure false-positive noise on every load of a scene using such an
effect. The caller a few lines below already does its own accurate
`pScene->renderTargets.count(name)` check and logs correctly for anything
genuinely missing, so the fix is simply to stop logging in `ParseSpecTexName`
for names it doesn't specifically recognize — that check already exists and
is authoritative. Confirmed live on 2942400953 (Satori Komeiji): the
`unknown tex "_rt_coc_..."` / `_rt_downscaled1_...` / `_rt_downscaled2_...`
and `not found in render targets` lines are gone entirely; the wallpaper's
own rendering was unaffected either way (it never depended on this log line).

**This is a logging fix, not a rendering fix — verified separately.** Testing
this surfaced a genuinely different, deeper issue that had been masked by the
same noise: "Bloom" and "Cutout Vignette" on that scene still fail to load,
but now for an actual GLSL compile error (`ERROR: 0:200: '' : compilation
terminated`), unrelated to render-target naming. Left as-is — the wallpaper
still renders correctly without those two effects, and root-causing a
specific shader's compile failure is a separate, unscoped investigation.

Not reported upstream (the repo is archived). Local patches.

## 9. Failed-effect layer dropped entirely, rendering as a solid black rect (`VulkanRender/SceneToRenderGraph.cpp`)

Fix 8 stopped `ParseSpecTexName` from logging false-positive noise for a
layer whose *every* declared effect fails to compile - but the underlying
render-graph behaviour for that case was never actually fixed, and it is
worse than "missing an effect": the base layer's own (perfectly valid)
material never reaches the screen at all.

**Why.** A layer with `HasImgEffect()` always redirects its base material's
render straight into the effect chain's first ping-pong buffer
(`ToGraphPass`, `output = imgeff->FirstTarget()`), *before* any effect is
compiled. Normally, resolving the effect chain (`SceneImageEffectLayer::
ResolveEffect`) renames the *last successful* effect's own output to the
real destination, relaying the whole chain (including the base material) to
the screen. With zero successful effects, `m_effects` is empty, that rename
never happens, and the base material's already-rendered content is simply
never composited anywhere - the region reads back as the render target's
clear value, i.e. solid black. Confirmed live on 3605722997 ("Simple Audio
Bars", a `float % int` GLSL error Wallpaper Engine's own compiler tolerates
but glslang correctly rejects) - a large black rectangle, not merely a
missing bar-graph overlay.

**First attempt was itself a crash bug.** The obvious fix - add a copy pass
relaying the ping-pong buffer straight to the real destination when
`EffectCount() == 0` - reproducibly took the whole GPU context down with
`VK_ERROR_DEVICE_LOST` (confirmed 3/3 across separate live plasmashell
deploys, each self-recovering only because the library was reverted and
plasmashell restarted). Root-caused via Vulkan validation layers (see
tooling section below): `CopyPass` (`CopyPass.cpp`) always issues
`vkCmdCopyImage` sized to the **source's full extent**, with **no scaling**.
A ping-pong buffer is sized to the effect layer's own declared canvas
(`WPSceneParser.cpp`'s `scene.renderTargets[effect_ppong_a] =
{wpimgobj.size...}`), which does not generally match the actual output
resolution - confirmed via the isolated test harness: a 2560x1440 source
copied into a 1280x720 destination, an out-of-bounds copy region
(`VUID-vkCmdCopyImage-dstOffset-00150`) that the driver turned into a hung
GPU context instead of a clean validation-only failure.

**Actual fix: guard the copy on matching size.** Only relay through when the
ping-pong buffer and the destination are recorded at the exact same
width/height (`scene.renderTargets`, compared before adding the pass) - true
for genuinely fullscreen effect layers (`wpimgobj.fullscreen`, whose
ping-pong buffer is dynamically bound to the real output size via
`.bind.screen = true`), false otherwise. When sizes don't match, falls back
to the prior (silent-drop) behaviour rather than attempting a copy that can
corrupt/hang the GPU. A fully general fix - scaling *any* mismatched layer
through correctly - would need a real sample-based blit pass (shader-based,
not `vkCmdCopyImage`), which does not exist in this renderer yet; out of
scope here given the size-matched case already covers this bug's actual
reported symptom. Verified live end-to-end on 3605722997: black rectangle is
gone, replaced by the base layer's actual (audio-bars-effect-free) content;
zero `VK_ERROR_*` in the log across the deploy, no coredump.

### Diagnostic tooling built for this (reusable)

Getting a *safe*, GPU-crash-proof repro - i.e. one that can't take the live
desktop down while iterating - took real setup, worth recording:

- **`standalone_view/` builds a real, tiny standalone test binary**
  (`sceneviewer`, GLFW+raw Vulkan, no Qt/plasmashell needed at all) that
  links the exact same `wescene-renderer` static lib the plugin does. Not
  wired into the main build (`add_subdirectory` in the outer
  `CMakeLists.txt` doesn't reach it) - configure and build it as its own
  tree: `cmake ../src/backend_scene/standalone_view -DBUILD_QML=OFF && cmake
  --build .` (needs `glfw-devel`, already-vendored `argparse` header). Run:
  `sceneviewer --valid-layer <assets-dir> <scene.json>` - `--valid-layer`
  requests `VK_LAYER_KHRONOS_validation` directly, no plasmashell/live-desktop
  involvement, so a crash only takes down this one disposable process.
- **The generic Qt `qml` CLI runner is NOT a viable substitute** - tried
  first, hit two dead ends: (1) it doesn't correctly negotiate the GL
  extension (`EXT_memory_object`) this renderer's Vulkan-GL interop needs,
  so scenes silently never load; (2) `source`/`assets` are `QUrl` C++
  properties (`SceneBackend.hpp`) - a bare path string assigned from QML
  does NOT coerce to a valid local-file QUrl (silently resolves to nothing);
  needs an explicit `file://` prefix.
- **A nested/sandboxed Wayland compositor (`cage`) is NOT reliable for this
  GPU specifically** - on this NVIDIA+Intel hybrid box, headless `cage`
  fails to grab the NVIDIA DRM device (already held by the real compositor)
  and silently falls back to the Intel iGPU + a broken zink/GL path -
  exercises a completely different code path than the live desktop, so a
  "survives" result there proves nothing. Running the harness as a plain
  separate process directly against the live Wayland session (still fully
  isolated from plasmashell as a *process*, just sharing the display) reached
  the real NVIDIA Vulkan path correctly and is what actually worked.
- **`vulkan-validation-layers` was not installed on the host** (an immutable
  Bazzite/rpm-ostree system - installing there needs a reboot to take
  effect, not worth it for a diagnostic-only package). Installed inside the
  `plasmabuild` toolbox instead (`sudo dnf install -y
  vulkan-validation-layers`) and extracted the two files the loader actually
  needs (`podman cp plasmabuild:/usr/lib64/libVkLayer_khronos_validation.so`
  and `.../explicit_layer.d/VkLayer_khronos_validation.json`) to a host
  directory, then ran the host-built `sceneviewer` binary directly (same
  Fedora 44 base as the toolbox, confirmed ABI-compatible - it just runs) with
  **both** `VK_LAYER_PATH` (manifest discovery) **and** `LD_LIBRARY_PATH`
  (the manifest's `library_path` is a bare relative filename - the loader
  `dlopen()`s it via the normal linker search path, not relative to the
  manifest's own directory; without `LD_LIBRARY_PATH` this fails with a
  misleading `VK_ERROR_LAYER_NOT_PRESENT` even though the manifest was found
  fine - only visible with `VK_LOADER_DEBUG=all`).
- **Note: `plasmabuild` is a `distrobox` container, not a `toolbox`-CLI one**
  (confirm via `podman inspect <name> --format '{{.Config.Labels}}'` -
  `manager:distrobox`) - the `toolbox` CLI refuses to `toolbox run` it
  ("container is too old"); use `distrobox enter plasmabuild -- <cmd>`
  instead, which works fine on the exact same container.

## Known remaining gap (renders fully black - not fixed this session)

**3448290956** ("Interactions" GBC Subaru puppet-rigged wallpaper) renders
completely black - not a partial/cosmetic issue like everything else in
this file, nothing draws at all. Traced (but deliberately not fixed - open-
ended binary reverse-engineering, different in character from every other
entry here) to `WPMdlParser.cpp`'s puppet/bone parser: every one of this
wallpaper's five face-rig puppet files (`脸_puppet.mdl` /face/,
`左眼白_puppet.mdl` /left eye white/, `左眼皮_puppet.mdl` /left eyelid/,
twice, `右眼皮_puppet.mdl` /right eyelid/) fails - four log `bones: 0`
after a full parse (`mdlv: 23`), the fifth hits an outright corrupted read,
`mdl wrong bone parent index 516095061` (obviously not a real bone index).
That corrupted value strongly suggests a byte-alignment mismatch earlier in
the parse - `WPMdlParser.cpp` is a heuristic, reverse-engineered binary
format with no spec (lots of "unk, skip N bytes" reads and format-version
branches already in the code, e.g. `alt_mdl_format`/`mdl.mdla` handling) -
consistent with the version-specific format gaps fixes 2 and (the .tex
side of) this whole file's earlier entries hit, but pinning down exactly
*which* field this wallpaper's format version handles differently would
need real trial-and-error against the actual file bytes, not just reading
code. A separate, unrelated shader bug also present on the same wallpaper:
effect "Iris Movement +" fails to compile (`'*' : wrong operand types` -
multiplying a vec4 by a vec2 - an author-side GLSL bug, same category as
the "Simple Audio Bars"/fix 9 shader error, not a renderer bug).

## Known remaining gaps (non-fatal)

- The 3776778760 scene still logs, but renders fine without them: a **video
  effect** whose shader won't compile (`'[]' : scalar integer expression`).
- The 2942400953 scene's **Bloom** and **Cutout Vignette** effects fail to
  load from an actual shader compile error (see fix 8) — renders fine without
  them.
- **Real shadow casting** is still not implemented (fix 6 only makes the
  shadow-atlas *resource* resolve; nothing renders depth into it).
- **3605722997's "Simple Audio Bars" effect** still doesn't render its own
  content (its shader has a genuine author-side GLSL error, `frequency % 64`
  on a float) - fix 9 stops it from corrupting the screen, but the bar-graph
  visualizer itself is still absent, same "renders fine without it" category
  as the other entries here.

## 10. SceneScript (`constantshadervalue.script`) never executed - added a real JS engine

Wallpaper Engine authors can attach a small JS snippet to a shader value
instead of a static constant - an ES6 module exporting `update(value)`,
called every frame, with an `engine.frametime`/`engine.runtime` global for
frame-rate-independent timing. This is how e.g. 3605722997's entrance
animation is *supposed* to fade out once (18s play, 0.5s fade) and disappear
- and it's genuinely common: any delayed reveal, pulsing glow, or
non-trivial animated value on a wallpaper Workshop item likely uses this.

**This renderer never implemented it at all.** Confirmed by an exhaustive
grep of the whole tree for any JS engine (mujs/quickjs/duktape/etc.) -
zero hits. The JSON parser only ever read the static `"value"` fallback
next to `"script"` and silently ignored the script text entirely
(`WPJson.cpp`'s `GetJsonValue`), so anything relying on a script just froze
forever at that static value - for 3605722997 specifically, frozen at
opacity 1, combined with this renderer's video/sprite playback having no
"play once" mode anywhere (`VideoTex.cpp` rewinds on EOF unconditionally,
`SpriteAnimation.hpp` wraps to frame 0 unconditionally) - the intro clip
just played on loop forever instead of fading out after one play.

**Added a real one: [quickjs-ng](https://github.com/quickjs-ng/quickjs)**
(MIT), vendored at `third_party/quickjs` (not part of `renderer-fixes.patch`
- see "Vendoring quickjs-ng" below). A different, GPL-3.0-licensed
open-source Wallpaper Engine Linux port
([Almamu/linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine))
already solves exactly this with the same engine - useful as an
architecture reference (one JSRuntime/JSContext per scene; a script is
compiled once as an ES6 module and its resulting module-namespace `JSValue`
is cached and reused for every later frame, which is what makes
module-scope state like `let elapsedTime = 0` actually persist between
calls instead of resetting every frame; `engine` is a plain object with C
getter-property bindings) - but GPL-3.0 code cannot be pulled into this
GPL-2.0 project (one-directional incompatibility, confirmed by reading both
projects' actual LICENSE files, not just assumed from the file's boilerplate
header), so nothing was copied from it; `WPJsScriptEngine.{hpp,cpp}` here is
an independent implementation written directly against QuickJS's own C API.

New files: `src/WPJsScriptEngine.{hpp,cpp}` (the engine itself, pimpl'd -
`quickjs.h` is never included outside this one `.cpp`). Threaded through the
existing constant-shader-value pipeline: `wpscene/WPMaterial.{h,cpp}` now
also captures a `constantshadervalueScripts` map alongside the existing
static-value map when a `"script"` key is present; `WPSceneParser.cpp`'s
`LoadConstvalue` carries it through into a new
`SceneMaterialCustomShader::constValueScripts` map
(`Scene/include/Scene/SceneMaterial.h`), keyed by the same resolved GLSL
uniform name as the existing `constValues`; `WPShaderValueUpdater.cpp`'s
per-frame `UpdateUniforms()` (already the home of every other
frame-varying uniform - camera matrices, mouse position, audio spectrum)
runs each one through `WPJsScriptEngine::RunUpdate()` and writes the result
into the same uniform slot the static path already writes to, keyed per
`(SceneNode*, glname)` pair so two layers that happen to share identical
script text still each get their own independent module-scope state.

**One real bug found and fixed via the isolated test harness (see fix 9's
tooling section) before ever touching the live desktop:** a completely
ordinary ~30-line script failed to even *compile*, throwing "Maximum call
stack size exceeded" - not a script problem. QuickJS's recursion-depth guard
(`js_check_stack_overflow`) compares the current C stack pointer against a
"top of stack" reference that, by default, is captured once, at
`JS_NewRuntime()` time. `WPJsScriptEngine` is constructed during scene
setup, but `RunUpdate()` is only ever called much later, from deep inside a
per-node call in `UpdateUniforms()` - itself reached through however many
frames of scene-graph traversal and per-frame update dispatch happened to
stack up by then. That ordinary C++ call depth alone was enough to eat
QuickJS's entire default 1MB budget (`JS_DEFAULT_STACK_SIZE`) before
QuickJS's own parser did anything deep at all. Fix: call
`JS_UpdateStackTop(rt)` at the top of `RunUpdate()` itself - immediately
before the only two calls in this file that can recurse into QuickJS's C
stack usage (`JS_Eval`/`JS_Call`) - so the reference reflects the actual
call site instead of wherever `JS_NewRuntime()` happened to run. Calling it
once per *frame* instead (tried first) was not suffient: `BeginFrame()`
runs once per frame near the top of the update sequence, at meaningfully
*less* call depth than deep inside per-node scene traversal - the reference
still went stale by the time execution actually reached `JS_Eval`.

Verified live end-to-end on 3605722997: no `VK_ERROR_*`, no coredump, no
regression on an unrelated wallpaper checked in the same harness run - and
functionally, the entrance animation now plays once and fades out exactly
as designed (confirmed at both the ~10s and ~40s marks post-restart: fully
faded, artwork underneath fully revealed, no loop-back).

### Vendoring quickjs-ng

Not part of `renderer-fixes.patch` (127K+ lines of vendored source would
swamp a patch meant to stay reviewable) - a separate step:

```sh
curl -sL "https://api.github.com/repos/quickjs-ng/quickjs/tarball/v0.16.1" \
    -o quickjs.tar.gz -H "Accept: application/vnd.github+json"
mkdir -p we-build/src/backend_scene/third_party/quickjs
tar xzf quickjs.tar.gz -C we-build/src/backend_scene/third_party/quickjs --strip-components=1
```

Then apply `renderer-fixes.patch` as usual, which wires it into
`third_party/CMakeLists.txt` (`add_subdirectory(quickjs EXCLUDE_FROM_ALL)` -
static `qjs` lib target only, its CLI/test executables excluded from the
default build) and links it into `src/CMakeLists.txt`'s
`WallpaperEngineKde`/`wescene-renderer` target.

## 11. Object "parent" field never composed - entrance animation lands in a corner

The other half of "the opening animation is looping and only in the
corner" (fix 10 was the looping half). `objects[].parent` - a WP Engine
scene object referencing an ancestor's id, meant to have its own origin
composed with that ancestor's - was never read anywhere in this parser
(confirmed by an exhaustive grep for the JSON key `"parent"` across the
whole tree: zero matches before this fix). Worse, "group" objects - ones
with no `image`/`particle`/`sound`/`light` key, existing purely to give a
set of children a shared coordinate frame - were silently skipped entirely
by the object-type dispatch loop, so they never even became a `SceneNode`
a child could reference.

For 3605722997's entrance-animation layer specifically: its authored local
origin, `(-1157.76, -808.69)`, is (almost exactly) the *negation* of its
group parent's own origin, `(1157.76, 808.69)` - once correctly composed
(`parent_origin + child_local_origin`), that resolves to world origin
`(0,0)`, the bottom-left corner of the scene's 2560x1440 canvas, which
combined with the object's `"alignment": "bottomleft"` produces a perfectly
centered, fullscreen quad exactly matching the canvas. With the `parent`
field silently ignored, the child's origin was instead used as-is as an
*absolute* world coordinate, landing the quad's center at `(122, -89)`
instead of `(1280, 720)` - numerically reconstructed and confirmed to
produce a quad whose visible intersection with the screen is only its
bottom-left ~55%x44%, matching the reported symptom exactly.

**Fix: use `SceneNode`'s own existing parent/child hierarchy** (`SceneNode.h`'s
`AppendChild()` + `m_parent`, and `SceneNode.cpp`'s `UpdateTrans()`, which
already correctly composes `m_trans = parent->ModelTrans() * GetLocalTrans()`
- this machinery was already complete and correct, just never actually used
by the scene parser for ordinary objects). `WPSceneParser.cpp` now:

- Tracks every node it creates in a new `ParseContext::id_node_map` (id ->
  `SceneNode`), populated as each object is parsed.
- Has a new pre-pass, `ParseGroupObjs()`, that runs before the main
  content-object loop and creates a bare `SceneNode` (no mesh, just a
  transform) for every content-less "group" object that has an id -
  registering it in `id_node_map` immediately, so content objects can find
  it regardless of which one appears first in the JSON array. A group's own
  `"visible"` is deliberately not checked - it exists only to anchor a
  coordinate frame, never to render or play anything itself.
- Resolves each object's `"parent"` (added as a new field on
  `wpscene::WPImageObject`, read alongside its existing `"id"` field) via a
  new `AppendToParentOrRoot()` helper: attach to the referenced parent node
  if found in `id_node_map`, otherwise fall back to the scene root exactly
  as before (so an object with no `"parent"` key, or one referencing an id
  this parser genuinely never created a node for, behaves identically to
  pre-fix - no regression for the common case).

Only wired into `WPImageObject` (what the reported bug needed) -
`WPParticleObject`/`WPLightObject` don't currently have any known scene
depending on parent composition, left as a natural follow-up if one turns
up rather than speculatively wired now.

Verified two ways before ever touching the live desktop: (1) temporary
logging at the resolution call site, confirming id=138 (the entrance
animation) correctly resolved parent id=145 to a real node - and, as a
bonus, that two *other*, previously-silently-broken parent references
elsewhere in the same scene (ids 49 and 163) now resolve too; (2) the
isolated Vulkan-validation harness, clean across this wallpaper and two
unrelated ones (no new `VK_ERROR_*`, no coredump). Confirmed live: the
corner artifact is gone at every point checked, including immediately after
a fresh restart while the entrance animation would still be active.

## 12. `playbackmode: "single"` never implemented - sound objects always looped forever

The remaining half of "the audio voices are garbled together" (3605722997
has two alternate-language intro voice-line sound objects, both
`playbackmode: "single"`). `WPSoundParser.cpp`'s `ToPlaybackMode()`
recognized exactly two strings, `"loop"` and `"random"` - anything else,
including `"single"`, silently fell back to `Loop`. `WPSoundStream` has no
"play once and stop" concept at all: `NextPcmData()` unconditionally calls
`Switch()` again whenever the current file ends, and `Switch()`'s index
wraps back to 0 once it passes the end of the path list - for a
single-path sound object (both of these are: one path each), that means
"restart the same one file, forever" from the moment the scene loads.

Added real `Single` mode support: `WPSoundStream` now counts how many times
`Switch()` has advanced (`m_switchCount`), and once that count reaches the
path list's length - every path has played through exactly once - further
reads return 0 frames (silence) instead of switching again.

**This is a real, complete fix for wallpapers that just want one-shot
audio on load - but it is not a complete fix for *this* wallpaper's actual
intent**, and it's worth being precise about why: WP Engine's real design
for these two objects is that NEITHER plays automatically at all - a
SceneScript on their shared parent (see fix 10/11's description of object
145) is supposed to pick exactly one of them (based on a language
property) and call that one's own `.play()` when the intro layer becomes
visible, explicitly stopping the other. This renderer has no mechanism for
a script to trigger/stop an individual sound object at all - confirmed by
reading `Audio/include/Audio/SoundManager.h`: its entire API is
`MountStream()` (fire-and-forget, no handle returned), `UnMountAll()` (every
mounted stream at once), and a *global* `Play()`/`Pause()`/`SetVolume()` -
there is no per-stream identity anywhere to attach a `.play()`/`.stop()`
binding to in the first place. Building that - a real handle-based
per-stream control API in `SoundManager`, a `thisScene.getLayer(name)`
registry spanning both image and sound objects, and `visible: {script}`
evaluation (a second, distinct scripting hook from fix 10's
`constantshadervalue.script`) - is a genuinely separate, comparably-sized
subsystem to fix 10's whole JS engine addition, not a small extension of
it. Deliberately not attempted in this session: scoped as a real follow-up
if this specific "select one of several script-gated audio tracks" pattern
turns out to matter beyond this one wallpaper.

Net effect of what *is* fixed here: both intro voice lines now play through
once (still overlapping each other, since both still start together on
scene load with no selection logic) and then go silent, rather than
looping over each other forever. Verified via the isolated Vulkan-
validation harness (clean, no regressions) and live (no `VK_ERROR_*`, no
coredump).
