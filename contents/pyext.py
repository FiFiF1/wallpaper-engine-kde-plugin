#!/bin/python3

import asyncio
import websockets
import json
import base64
import math
import os
import platform
import re

from pathlib import Path

from typing import Callable,Any,Optional

# import functools;



class Main:
    def __init__(self):
        self.config_dir: Path = self.__config_dir()
        self.config_wallpaper_dir: Path = self.config_dir / 'wallpaper'

        self.config_wallpaper_dir.mkdir(parents=True, exist_ok=True)

    def __config_dir(self) -> Path:
        config_name: str = "wekde"
        xdg_config_home: Optional[str] = os.getenv("XDG_CONFIG_HOME")
        if xdg_config_home:
            return Path(xdg_config_home) / config_name
        return Path.home() / ".config" / config_name
    def __wallpaper_config_file(self, id: str) -> Path:
        return self.config_wallpaper_dir / (id + '.json')

    def read_wallpaper_config(self, id: str) -> dict:
        cfg_file: Path = self.__wallpaper_config_file(id)
        if not cfg_file.exists():
            return dict()

        with open(cfg_file, "r") as f:
            return json.load(f)

    def write_wallpaper_config(self, id: str, changed: dict) -> None:
        cfg: dict = self.read_wallpaper_config(id)
        cfg.update(changed)
        cfg_file: Path = self.__wallpaper_config_file(id)

        with open(cfg_file, "w+") as f:
            json.dump(cfg, f)

    def reset_wallpaper_config(self, id: str) -> None:
        cfg_file: Path = self.__wallpaper_config_file(id)
        cfg_file.unlink()

    def delete_wallpaper_config_key(self, id: str, key: str) -> None:
        """Reset a single per-wallpaper setting back to its default, leaving
        every other saved override untouched. write_wallpaper_config() only
        merges (dict.update) - it can add or overwrite a key but never
        remove one - so undoing just one setting needed a real delete, not
        another write."""
        cfg: dict = self.read_wallpaper_config(id)
        if key not in cfg:
            return
        del cfg[key]
        cfg_file: Path = self.__wallpaper_config_file(id)
        with open(cfg_file, "w+") as f:
            json.dump(cfg, f)

    def __favorites_file(self) -> Path:
        return self.config_dir / 'favorites.json'

    def read_favorites(self) -> list:
        """Favourites, shared across every monitor.

        They used to live in the wallpaper plugin's own Plasma config, which is
        per-containment: favouriting something while the dialog was open on one
        screen left the other screens' favourites untouched, so they looked like
        they kept vanishing. Plasma also only writes that config on OK/Apply, so
        closing the dialog any other way dropped them entirely.
        """
        f = self.__favorites_file()
        if not f.exists():
            return []
        try:
            with open(f, "r") as fh:
                data = json.load(fh)
        except Exception:
            return []
        if isinstance(data, dict):
            data = data.get("favor", [])
        return [str(x) for x in data] if isinstance(data, list) else []

    def write_favorites(self, ids: list) -> None:
        f = self.__favorites_file()
        tmp = f.with_name(f.name + ".tmp")
        with open(tmp, "w") as fh:
            json.dump({"favor": [str(x) for x in (ids or [])]}, fh)
        # Atomic replace: a half-written favourites file would read back as none
        # at all, which is exactly the failure being fixed here.
        tmp.replace(f)

    def path_exists(self, path: str) -> bool:
        """Cheap existence check, used to notice a workshop item finishing its
        download without rescanning the whole library on a timer."""
        try:
            return Path(str(path)).exists()
        except Exception:
            return False

    def record_last_applied(self, wid: str) -> bool:
        """Note the wallpaper just applied from the config dialog, so that if it
        goes on to crash the shell, wekde-crashguard has a strong hint about which
        one to disable first. The crash guard reads this file; nothing else does.
        Best-effort - failure here must never disturb applying a wallpaper."""
        try:
            w = re.sub(r"\D", "", str(wid or ""))
            if not w:
                return False
            import time
            d = Path.home() / ".local" / "share" / "wekde"
            d.mkdir(parents=True, exist_ok=True)
            (d / "last-applied").write_text(
                "%d %s" % (int(time.time()), w), encoding="utf-8")
            return True
        except Exception:
            return False

    # Audio a wallpaper can actually play. Kept here rather than guessed in QML
    # because answering it means reading files.
    __AUDIO_EXT = (".mp3", ".ogg", ".wav", ".flac", ".m4a", ".aac", ".opus")

    def __pkg_header(self, pkg: Path) -> "tuple[list, int]":
        """Parse a Wallpaper Engine .pkg header: (entries, payload_base_offset).

        Every version seen in the wild (PKGV0001 through PKGV0024) uses the same
        header: a length-prefixed version string, an entry count, then per entry
        a length-prefixed name plus offset and length (both relative to the byte
        right after the header). Shared by every .pkg reader below so the format
        is parsed in exactly one place.
        """
        import struct

        with pkg.open("rb") as f:
            head = f.read(1 << 20)
        off = 0

        def take_int() -> int:
            nonlocal off
            (v,) = struct.unpack_from("<i", head, off)
            off += 4
            return v

        def take_str() -> str:
            nonlocal off
            n = take_int()
            if n < 0 or n > (1 << 16):
                raise ValueError("bad string length in pkg header")
            s = head[off:off + n].decode("utf-8", "replace")
            off += n
            return s

        take_str()                      # version, e.g. "PKGV0024"
        count = take_int()
        if count < 0 or count > 100000:
            raise ValueError("bad entry count in pkg header")
        entries: list = []
        for _ in range(count):
            name = take_str()
            entry_off = take_int()
            entry_len = take_int()
            entries.append((name, entry_off, entry_len))
        return entries, off

    def __pkg_entry_names(self, pkg: Path) -> list:
        """File names inside a .pkg. The payload is never touched, so this
        stays cheap even on a 200 MB scene."""
        entries, _base = self.__pkg_header(pkg)
        return [name for name, _o, _l in entries]

    def __pkg_read_entry(self, pkg: Path, name: str, max_len: int = 8 << 20) -> Optional[bytes]:
        """Read one entry's payload out of a .pkg by name, or None if absent.
        Bounded to max_len (default 8MB - scene.json is a few KB to low hundreds
        of KB in practice) so a corrupt length can't force a huge read."""
        entries, base = self.__pkg_header(pkg)
        for name_i, entry_off, entry_len in entries:
            if name_i != name:
                continue
            if entry_len < 0 or entry_len > max_len:
                return None
            with pkg.open("rb") as f:
                f.seek(base + entry_off)
                return f.read(entry_len)
        return None

    def __dir_has_audio(self, root: Path, max_entries: int = 4000) -> bool:
        seen = 0
        for cur, _dirs, files in os.walk(root):
            for name in files:
                seen += 1
                if seen > max_entries:
                    return False
                if name.lower().endswith(self.__AUDIO_EXT):
                    return True
        return False

    def wallpaper_caps(self, path: str) -> dict:
        """What one wallpaper can actually do, so the settings page can hide
        controls that would do nothing for it.

        The honest default is True: a control that turns out to be useless is a
        far smaller annoyance than a missing one, so anything that cannot be
        determined is reported as present rather than absent.
        """
        import subprocess
        import urllib.parse

        caps = {"type": "", "sound": True, "audioProcessing": False,
                "known": False, "error": ""}

        raw = str(path or "")
        if raw.startswith("file://"):
            raw = urllib.parse.unquote(raw[7:])
        if not raw:
            return dict(caps, error="no path")

        folder = Path(raw)
        if folder.is_file():
            folder = folder.parent
        if not folder.is_dir():
            return dict(caps, error="not a directory: " + str(folder))

        try:
            project = json.loads(
                (folder / "project.json").read_text(encoding="utf-8", errors="replace"))
        except Exception as e:
            return dict(caps, error=str(e))

        wtype = str(project.get("type", "")).lower()
        wfile = str(project.get("file", ""))
        general = project.get("general") or {}
        caps["type"] = wtype
        caps["audioProcessing"] = bool(general.get("supportsaudioprocessing", False))
        caps["known"] = True

        if wtype == "video":
            # An mp4 either carries an audio stream or it does not; ffprobe
            # answers that outright in about 200 ms.
            target = folder / wfile
            if not target.is_file():
                return caps
            try:
                out = subprocess.run(
                    ["ffprobe", "-v", "error", "-select_streams", "a",
                     "-show_entries", "stream=codec_type", "-of", "csv=p=0",
                     str(target)],
                    capture_output=True, text=True, timeout=20)
                caps["sound"] = bool(out.stdout.strip())
            except Exception:
                pass                    # no ffprobe, or it choked - assume sound
        elif wtype == "scene":
            # Scenes keep their assets in scene.pkg; a scene with sound ships
            # the audio files inside it, under sounds/.
            pkg = folder / "scene.pkg"
            if pkg.is_file():
                try:
                    names = self.__pkg_entry_names(pkg)
                    caps["sound"] = any(n.lower().endswith(self.__AUDIO_EXT)
                                        for n in names)
                except Exception:
                    pass
            else:
                caps["sound"] = self.__dir_has_audio(folder)
        elif wtype == "web":
            # Web wallpapers play their own audio through the page. Mute
            # genuinely works (QtWebView.qml binds WebEngineView.audioMuted
            # to it), but there is no per-wallpaper Volume control wired for
            # the web backend at all - a finer distinction than "sound: bool"
            # can express, so leave sound at its honest default (True/
            # unknown) rather than hiding a control (Mute) that actually
            # works. Previously hard-set to False here, which incorrectly
            # hid Mute Audio for every web wallpaper once the per-wallpaper
            # Option panel started using this same capability check.
            pass

        return caps

    # ------------------------------------------------------------ resolution
    # Resolution is not a field Wallpaper Engine puts in project.json for any
    # wallpaper type, so it has to be derived per type and is worth caching:
    # video goes through ffprobe (~200ms/item) and scene through a .pkg
    # payload read, so scanning the whole library live on every settings-page
    # open would be slow. QML calls this in small batches (see
    # WallpaperListModel.qml) and results are cached to disk keyed by folder
    # mtime, so repeat scans of an unchanged library are instant.

    __RES_TIERS = (
        (7000, "8K"), (3800, "4K"), (2500, "1440p"), (1800, "1080p"), (1, "SD"),
    )

    def __resolution_tier(self, w: int, h: int) -> str:
        if not w or not h:
            return "Unknown"
        long_edge = max(w, h)
        for threshold, tier in self.__RES_TIERS:
            if long_edge >= threshold:
                return tier
        return "Unknown"

    def __resolution_cache_path(self) -> Path:
        d = Path.home() / ".local" / "share" / "wekde"
        d.mkdir(parents=True, exist_ok=True)
        return d / "resolution-cache.json"

    def __load_resolution_cache(self) -> dict:
        try:
            return json.loads(self.__resolution_cache_path().read_text(encoding="utf-8"))
        except Exception:
            return {}

    def __save_resolution_cache(self, cache: dict) -> None:
        try:
            self.__resolution_cache_path().write_text(
                json.dumps(cache), encoding="utf-8")
        except Exception:
            pass                         # best-effort; a lost cache just means a rescan

    def __probe_video_resolution(self, target: Path) -> "tuple[int, int]":
        try:
            out = subprocess.run(
                ["ffprobe", "-v", "error", "-select_streams", "v:0",
                 "-show_entries", "stream=width,height", "-of", "csv=p=0",
                 str(target)],
                capture_output=True, text=True, timeout=20)
            parts = out.stdout.strip().split(",")
            if len(parts) == 2:
                return int(parts[0]), int(parts[1])
        except Exception:
            pass
        return 0, 0

    def __probe_scene_resolution(self, folder: Path) -> "tuple[int, int]":
        # A scene's own scene.json declares the canvas it was authored at
        # (general.orthogonalprojection) - the closest thing to a "native
        # resolution" a scene has, since there is no single output texture.
        raw: Optional[bytes] = None
        pkg = folder / "scene.pkg"
        if pkg.is_file():
            try:
                raw = self.__pkg_read_entry(pkg, "scene.json")
            except Exception:
                raw = None
        else:
            unpacked = folder / "scene.json"
            if unpacked.is_file():
                try:
                    raw = unpacked.read_bytes()
                except Exception:
                    raw = None
        if raw is None:
            return 0, 0
        try:
            scene = json.loads(raw.decode("utf-8", "replace"))
            op = ((scene.get("general") or {}).get("orthogonalprojection") or {})
            return int(op.get("width") or 0), int(op.get("height") or 0)
        except Exception:
            return 0, 0

    def resolve_resolutions(self, items: list) -> dict:
        """items: [{"workshopid", "path" (folder, file:// or native), "type"}].
        Returns {workshopid: {"tier": str, "w": int, "h": int}} for exactly the
        items passed in. `type: "web"` items are answered "Unknown" without
        touching disk - a web wallpaper has no single native resolution."""
        cache = self.__load_resolution_cache()
        result: dict = {}
        dirty = False

        for item in items or []:
            wid = str(item.get("workshopid") or "")
            raw_path = str(item.get("path") or "")
            wtype = str(item.get("type") or "").lower()
            if not wid or not raw_path:
                continue

            folder = Path(raw_path)
            if folder.is_file():
                folder = folder.parent

            if wtype == "web":
                result[wid] = {"tier": "Unknown", "w": 0, "h": 0}
                continue

            try:
                mtime = folder.stat().st_mtime
            except Exception:
                mtime = 0

            cache_key = str(folder)
            cached = cache.get(cache_key)
            if cached and cached.get("mtime") == mtime:
                result[wid] = {"tier": cached["tier"], "w": cached["w"], "h": cached["h"]}
                continue

            w, h = 0, 0
            try:
                if wtype == "video":
                    project = json.loads(
                        (folder / "project.json").read_text(encoding="utf-8", errors="replace"))
                    wfile = str(project.get("file", ""))
                    target = folder / wfile
                    if target.is_file():
                        w, h = self.__probe_video_resolution(target)
                elif wtype == "scene":
                    w, h = self.__probe_scene_resolution(folder)
            except Exception:
                w, h = 0, 0

            tier = self.__resolution_tier(w, h)
            cache[cache_key] = {"mtime": mtime, "tier": tier, "w": w, "h": h}
            dirty = True
            result[wid] = {"tier": tier, "w": w, "h": h}

        if dirty:
            self.__save_resolution_cache(cache)
        return result

    # ---------------------------------------------------------------- steam
    # Subscribing is an account change, so it has to be an authenticated request
    # to Steam - there is no local way to do it. Rather than ask for a password,
    # this borrows the session the Steam client already has: its embedded
    # browser keeps a steamLoginSecure cookie, and the client runs with
    # --password-store=basic, so that store is encrypted with Chromium's fixed
    # local key ("peanuts") rather than a keyring secret.
    #
    # The token is read on demand, kept only for the one request, and never
    # written to disk, logged, or placed in any error string. Every failure is
    # reported as a plain flag so the caller can fall back to opening the item
    # in Steam.

    def __steam_cookie_db(self) -> Optional[Path]:
        base = Path.home() / ".local" / "share" / "Steam" / "config" / "htmlcache"
        for rel in ("Default/Network/Cookies", "Default/Cookies",
                    "Network/Cookies", "Cookies"):
            p = base / rel
            if p.is_file():
                return p
        return None

    def __aes_cbc_decrypt(self, key: bytes, blob: bytes) -> bytes:
        iv = b" " * 16
        try:
            from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
            dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
            return dec.update(blob) + dec.finalize()
        except ImportError:
            pass
        try:
            from Crypto.Cipher import AES  # pycryptodome
            return AES.new(key, AES.MODE_CBC, iv).decrypt(blob)
        except ImportError:
            pass
        import subprocess
        out = subprocess.run(
            ["openssl", "enc", "-d", "-aes-128-cbc", "-nopad",
             "-K", key.hex(), "-iv", iv.hex()],
            input=blob, capture_output=True, timeout=15)
        if out.returncode != 0:
            raise RuntimeError("openssl could not decrypt the cookie store")
        return out.stdout

    def __decrypt_cookie(self, key: bytes, encrypted: bytes) -> str:
        if not encrypted:
            return ""
        if encrypted[:3] not in (b"v10", b"v11"):
            return encrypted.decode("utf-8", "replace")  # already plaintext
        plain = self.__aes_cbc_decrypt(key, encrypted[3:])
        if not plain:
            return ""
        pad = plain[-1]                                   # strip PKCS7 padding
        if 1 <= pad <= 16:
            plain = plain[:-pad]
        # Chromium 124+ prefixes the plaintext with a 32-byte domain hash.
        # Cookie values are printable, so a non-printable start means it is there.
        if len(plain) > 32 and any(b < 0x20 or b > 0x7E for b in plain[:32]):
            plain = plain[32:]
        return plain.decode("utf-8", "replace")

    def __steam_web_session(self) -> dict:
        """steamLoginSecure and sessionid from the running client's cookie store.

        Returns {} when there is no usable session, rather than raising, so the
        caller can quietly fall back to opening Steam.
        """
        import hashlib
        import shutil
        import sqlite3
        import tempfile
        import urllib.parse

        db = self.__steam_cookie_db()
        if db is None:
            return {}

        # Steam holds the store open; copy it so the read cannot block, and so
        # nothing here can ever write to Steam's own file.
        tmpdir = tempfile.mkdtemp(prefix="wekde-cookies-")
        try:
            copy = Path(tmpdir) / "Cookies"
            shutil.copy2(db, copy)
            for extra in ("-wal", "-shm"):
                side = Path(str(db) + extra)
                if side.is_file():
                    shutil.copy2(side, str(copy) + extra)

            con = sqlite3.connect("file:%s?mode=ro" % copy, uri=True)
            try:
                rows = con.execute(
                    "SELECT name, value, encrypted_value FROM cookies "
                    "WHERE host_key LIKE '%steamcommunity.com' "
                    "   OR host_key LIKE '%steampowered.com'").fetchall()
            finally:
                con.close()

            key = hashlib.pbkdf2_hmac("sha1", b"peanuts", b"saltysalt", 1, 16)
            found: dict = {}
            for name, value, enc in rows:
                if name not in ("steamLoginSecure", "sessionid"):
                    continue
                try:
                    got = value or self.__decrypt_cookie(key, enc or b"")
                except Exception:
                    continue
                if got and name not in found:
                    found[name] = got

            login = urllib.parse.unquote(found.get("steamLoginSecure", ""))
            if "||" not in login:
                return {}
            steamid, token = login.split("||", 1)
            if not steamid.isdigit() or not token:
                return {}
            return {"steamid": steamid, "token": token,
                    "sessionid": found.get("sessionid", "")}
        except Exception:
            return {}
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def steam_session_status(self) -> dict:
        """Whether a usable Steam session exists - deliberately says nothing
        about what it is beyond the (public) account id. Safe to log and show."""
        s = self.__steam_web_session()
        if not s:
            return {"ok": False,
                    "reason": "No cached Steam login found. Is Steam signed in?"}
        return {"ok": True, "steamid": s["steamid"]}

    def __steam_change_subscription(self, id: str, subscribe: bool) -> dict:
        import urllib.error
        import urllib.parse
        import urllib.request

        wid = re.sub(r"\D", "", str(id or ""))
        if not wid:
            return {"ok": False, "error": "no id"}

        session = self.__steam_web_session()
        if not session:
            return {"ok": False, "needSteam": True,
                    "error": "No cached Steam login found."}

        verb = "Subscribe" if subscribe else "Unsubscribe"

        def post(url: str, data: dict, headers: dict) -> tuple:
            body = urllib.parse.urlencode(data).encode()
            req = urllib.request.Request(url, data=body, headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=20) as resp:
                    return resp.status, resp.read().decode("utf-8", "replace")
            except urllib.error.HTTPError as e:
                return e.code, ""
            except Exception:
                return 0, ""

        # The published-file web API takes the token directly, so it needs no
        # matching sessionid.
        status, text = post(
            "https://api.steampowered.com/IPublishedFileService/%s/v1/" % verb,
            {"access_token": session["token"], "publishedfileid": wid,
             "appid": "431960", "list_type": "1", "notify_client": "true"},
            {"Content-Type": "application/x-www-form-urlencoded"})
        if status == 200:
            return {"ok": True, "via": "webapi"}

        # Fall back to the endpoint the Workshop page itself posts to. Its CSRF
        # check only requires the cookie and the form field to agree, so a
        # freshly minted sessionid is fine when the store has none.
        sessionid = session.get("sessionid") or os.urandom(12).hex()
        status, text = post(
            "https://steamcommunity.com/sharedfiles/%s" % verb.lower(),
            {"id": wid, "appid": "431960", "sessionid": sessionid},
            {"Content-Type": "application/x-www-form-urlencoded",
             "Referer": "https://steamcommunity.com/sharedfiles/filedetails/?id=" + wid,
             "Origin": "https://steamcommunity.com",
             "User-Agent": "Mozilla/5.0",
             "Cookie": "sessionid=%s; steamLoginSecure=%s" % (
                 sessionid,
                 urllib.parse.quote("%s||%s" % (session["steamid"], session["token"]))),
             })
        if status == 200 and '"success":1' in text.replace(" ", ""):
            return {"ok": True, "via": "community"}

        # Deliberately vague: nothing derived from the token goes in here.
        return {"ok": False, "needSteam": True,
                "error": "Steam refused the %s (HTTP %d)." % (verb.lower(), status)}

    def steam_subscribe(self, id: str) -> dict:
        return self.__steam_change_subscription(id, True)

    def steam_unsubscribe(self, id: str) -> dict:
        return self.__steam_change_subscription(id, False)

    def workshop_download_state(self, library: str, id: str) -> dict:
        """Progress of one item's download, for the tile's loading indicator.

        Two independent sources are combined so the answer is trustworthy while
        a download is in flight and the instant it finishes:

        - bytes on disk, summed from the content folder (and Steam's transient
          downloads/temp staging), which climbs as the download proceeds;
        - the item's record in appworkshop_431960.acf, which Steam writes when
          the install completes and which carries the final size.

        `target` is the final size when Steam already knows it (a reinstall or
        update), else 0; the caller fetches the size from the item page for a
        brand-new download so the bar can still be proportional.
        """
        import urllib.parse

        wid = re.sub(r"\D", "", str(id or ""))
        if not wid:
            return {"error": "no id"}

        lib = str(library or "")
        if lib.startswith("file://"):
            lib = urllib.parse.unquote(lib[7:])
        ws = Path(lib) / "steamapps" / "workshop"

        def dsize(p: Path) -> int:
            total = 0
            if p.is_dir():
                for cur, _dirs, files in os.walk(p):
                    for name in files:
                        try:
                            total += (Path(cur) / name).stat().st_size
                        except OSError:
                            pass
            return total

        content = ws / "content" / "431960" / wid
        on_disk = dsize(content)
        staging = (dsize(ws / "downloads" / "431960" / wid)
                   + dsize(ws / "temp" / "431960" / wid))
        present = content.is_dir() and on_disk > 0

        installed = False
        target = 0
        needs_update = False
        try:
            text = (ws / "appworkshop_431960.acf").read_text(
                encoding="utf-8", errors="replace")
        except Exception:
            text = ""
        if text:
            inst = re.search(r'"WorkshopItemsInstalled"\s*\{(.*?)\n\t\}', text, re.S)
            if inst:
                block = re.search(r'"' + wid + r'"\s*\{(.*?)\}', inst.group(1), re.S)
                if block:
                    installed = True
                    sm = re.search(r'"size"\s*"(\d+)"', block.group(1))
                    if sm:
                        target = int(sm.group(1))
            det = re.search(r'"WorkshopItemDetails"\s*\{(.*?)\n\t\}', text, re.S)
            if det:
                block = re.search(r'"' + wid + r'"\s*\{(.*?)\}', det.group(1), re.S)
                if block:
                    cur = re.search(r'"manifest"\s*"(\d+)"', block.group(1))
                    lat = re.search(r'"latest_manifest"\s*"(\d+)"', block.group(1))
                    if cur and lat and cur.group(1) != lat.group(1):
                        needs_update = True

        return {
            "id": wid,
            "present": present,
            "installed": installed,
            "needsUpdate": needs_update,
            "onDisk": on_disk,
            "staging": staging,
            "target": target,
            "error": "",
        }

    def workshop_item(self, id: str) -> dict:
        """Full detail for one Workshop item.

        The item pages, unlike the browse listing, still use stable class names
        (workshopItemTitle, workshopItemDescription, stats_table), so these can
        be matched directly.
        """
        import html as htmlmod
        import urllib.request

        wid = re.sub(r"\D", "", str(id or ""))
        if not wid:
            return {"error": "no id"}

        url = "https://steamcommunity.com/sharedfiles/filedetails/?id=" + wid
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                p = resp.read().decode("utf-8", "replace")
        except Exception as e:
            return {"error": str(e)}

        def first(pattern, default=""):
            m = re.search(pattern, p, re.S)
            return m.group(1).strip() if m else default

        title = htmlmod.unescape(first(r'<div class="workshopItemTitle">(.*?)</div>', wid))
        author = htmlmod.unescape(first(r'<div class="friendBlockContent">\s*([^<\r\n]+)'))

        desc_html = first(r'<div class="workshopItemDescription"[^>]*>(.*?)</div>')
        desc = re.sub(r'<br\s*/?>', '\n', desc_html)
        desc = re.sub(r'<[^>]+>', '', desc)
        desc = htmlmod.unescape(desc).strip()

        # The preview element's id is not consistent between items: it can be
        # previewImageMain, previewImage, previewImage0 or previewImage<digits>,
        # and previewImageEnlarged often exists with no src at all. Take the
        # first id starting with "preview" that actually carries a src,
        # preferring the main one where it exists.
        preview = first(r'id="previewImageMain"[^>]*src="([^"]+)"')
        if not preview:
            for pid, src in re.findall(r'id="(preview\w*)"[^>]*src="([^"]+)"', p):
                if src:
                    preview = src
                    break
        # Served small to fit the page layout; ask the CDN for a bigger render.
        preview = re.sub(r'imw=\d+', 'imw=1024', preview)
        preview = re.sub(r'imh=\d+', 'imh=1024', preview)

        tags = [htmlmod.unescape(t).strip()
                for t in re.findall(r'<a href="[^"]*requiredtags[^"]*">([^<]+)</a>', p)]

        # "452 / Unique Visitors", "8,044 / Current Subscribers", ...
        stats = []
        table = re.search(r'class="stats_table">(.*?)</table>', p, re.S)
        if table:
            for value, label in re.findall(r'<td>([^<]+)</td>\s*<td>([^<]+)</td>', table.group(1)):
                stats.append({"label": htmlmod.unescape(label).strip(),
                              "value": htmlmod.unescape(value).strip()})

        # Left column holds the labels (File Size, Posted, Updated), right the values.
        labels = [htmlmod.unescape(x).strip()
                  for x in re.findall(r'class="detailsStatLeft">\s*([^<]+)', p)]
        values = [htmlmod.unescape(x).strip()
                  for x in re.findall(r'class="detailsStatRight">\s*([^<]+)', p)]
        details = [{"label": l, "value": v} for l, v in zip(labels, values)]

        rating = first(r'fileRatingDetails"><img src="[^"]*?(\d)-star')
        num_ratings = first(r'class="numRatings">([^<]+)<')

        return {
            "id": wid,
            "title": title,
            "author": author,
            "description": desc,
            "preview": preview,
            "tags": tags,
            "stats": stats,
            "details": details,
            "rating": rating,
            "num_ratings": num_ratings,
            "error": "",
        }

    def workshop_browse(self, sort: str = "trend", page: int = 1,
                        query: str = "", tags: list = None, days: int = 0) -> dict:
        """List Steam Workshop items for Wallpaper Engine.

        Deliberately parsed structurally - by the /filedetails/?id= link and the
        image and text that follow it - rather than by CSS class. Steam's
        workshop pages are built with hashed class names (tK5agp5sRy8-) that
        change on every deploy, so anything keyed to them breaks within weeks.

        Only public, already-visible listing data is read. Subscribing still
        happens in Steam itself; nothing here logs in or acts on the account.
        """
        import html as htmlmod
        import urllib.parse
        import urllib.request

        allowed = ("trend", "mostrecent", "toprated", "totaluniquesubscribers")
        if sort not in allowed:
            sort = "trend"
        try:
            page = max(1, int(page))
        except Exception:
            page = 1

        params = {
            "appid": "431960",
            "browsesort": sort,
            "section": "readytouseitems",
            "p": str(page),
        }
        if query:
            params["searchtext"] = query
        # Steam's own workshop UI windows "trend" sort by a day count (its
        # newer client-side state calls this trend_days, but that key is inert
        # on the page this scrapes - "days" on the classic query string is the
        # one that actually changes the server-rendered results, confirmed live:
        # 1/7/30/90/180/365 each return a distinct, progressively wider set;
        # 0 or omitted defaults to Steam's own default (7, "this week"); nothing
        # past 365 narrows or widens further, so there is no working "all time"
        # value via this endpoint).
        allowed_days = (1, 7, 30, 90, 180, 365)
        try:
            days = int(days)
        except Exception:
            days = 0
        if sort == "trend" and days in allowed_days:
            params["days"] = str(days)

        # Steam ANDs requiredtags together, so these are include-filters: the
        # local library's filters hide things, these narrow the search.
        pairs = list(params.items())
        for t in (tags or []):
            t = str(t).strip()
            if t:
                pairs.append(("requiredtags[]", t))

        url = "https://steamcommunity.com/workshop/browse/?" + urllib.parse.urlencode(pairs)
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                page_html = resp.read().decode("utf-8", "replace")
        except Exception as e:
            return {"items": [], "error": str(e)}

        # Each item appears twice on the page: once as the anchor wrapping its
        # preview image, once as the anchor wrapping its title. Merge the two
        # rather than dropping the duplicate - skipping it kept the image-only
        # occurrence and every title came back empty.
        order = []
        by_id = {}
        anchor = 'https://steamcommunity.com/sharedfiles/filedetails/?id='
        blocks = re.split(r'(?=<a href="' + re.escape(anchor) + r'\d+")', page_html)
        for b in blocks[1:]:
            m = re.match(r'<a href="[^"]*id=(\d+)"', b)
            if not m:
                continue
            wid = m.group(1)
            if wid not in by_id:
                by_id[wid] = {"id": wid, "title": "", "author": "", "preview": ""}
                order.append(wid)
            entry = by_id[wid]

            if not entry["preview"]:
                img = re.search(r'<img src="([^"]+)"', b[:2000])
                if img:
                    entry["preview"] = img.group(1)

            if not entry["title"]:
                texts = [htmlmod.unescape(t).strip()
                         for t in re.findall(r'>([^<>{}]{2,150})<', b[:4000])]
                texts = [t for t in texts if t and not t.startswith('&')]
                if texts:
                    entry["title"] = texts[0]
                    for t in texts[1:5]:
                        if t.lower().startswith("by "):
                            entry["author"] = t[3:].strip()
                            break

        items = []
        for wid in order:
            e = by_id[wid]
            if not e["title"]:
                e["title"] = wid
            items.append(e)

        return {"items": items, "error": ""}

    def translate(self, text: str, target: str = "en") -> str:
        """Translate wallpaper text (titles and descriptions are frequently in
        Chinese, Japanese or Russian) using Google's public translate endpoint.

        This sends the given text to Google. It is only ever called when the
        user presses the Translate button on a wallpaper, never automatically.

        The RPC loop is synchronous, so the timeout is kept short: a hung
        request would stall this helper's other calls (file reads) too. Errors
        come back as a message rather than an exception so the UI can show
        something useful instead of silently doing nothing.
        """
        import urllib.parse
        import urllib.request

        text = (text or "").strip()
        if not text:
            return ""

        url = (
            "https://translate.googleapis.com/translate_a/single"
            "?client=gtx&sl=auto&tl=" + urllib.parse.quote(target) +
            "&dt=t&q=" + urllib.parse.quote(text[:4500])
        )
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        try:
            with urllib.request.urlopen(req, timeout=8) as resp:
                data = json.load(resp)
        except Exception as e:
            return "[translation failed: %s]" % e

        try:
            # [[[chunk, original, ...], [chunk, original, ...], ...], ...]
            return "".join(seg[0] for seg in data[0] if seg and seg[0])
        except Exception:
            return "[translation failed: unexpected response]"

class Jsonrpc:
    def __init__(self):
        self.method_map = dict()

    def add_method(self, func: Callable) -> Callable:
        self.method_map[func.__name__] = func
        return func

    def add_class_method(self, obj: Any, func: Callable) -> None:
        def wrapper(*args):
            func(obj, *args)
        self.method_map[func.__name__] = wrapper

    def handle(self, msg) -> str:
        j: dict = {}
        error = None
        try:
            j = json.loads(msg)
        except Exception as e:
            error = repr(e)
            return json.dumps({"id": -1, "error": error})

        result = {"id": j.get("id")}
        method = j.get("method")
        if method in self.method_map:
            func = self.method_map[method]
            params = j.get("params") or []
            try:
                result["result"] = func(*params)
            except Exception as e:
                error = repr(e)
        else:
            error = "jsonrpc no such func"
        if error:
            result["error"] = error
        return json.dumps(result)

M = Main()
jrpc = Jsonrpc()


@jrpc.add_method
def version() -> str:
    return platform.python_version()


@jrpc.add_method
def readfile(path: str) -> str:
    with open(path, "rb") as f:
        data: bytes = f.read()
        return base64.b64encode(data).decode("ascii")


@jrpc.add_method
def get_dir_size(path: str, depth: int) -> int:
    glob_strs: list[str] = (
        ["**/*"]
        if depth <= 0
        else ["/".join(["*" for _ in range(i + 1)]) for i in range(depth)]
    )
    root_directory: Path = Path(path)
    return sum(
        [
            sum(f.stat().st_size for f in root_directory.glob(s) if f.is_file())
            for s in glob_strs
        ]
    )


@jrpc.add_method
def get_folder_list(path: str, _opt: dict = {}) -> Optional[dict]:
    def gen_item(f: Path) -> dict:
        stat: os.stat_result = f.stat()
        return {"name": f.name, "mtime": math.floor(stat.st_mtime)}

    opt: dict = get_folder_list.default_opt.copy()
    opt.update(_opt)
    opt_only_dir = opt["only_dir"]

    def path_filter(p: Path) -> bool:
        return p.is_dir() if opt_only_dir else True

    folder: Optional[Path] = next(
        filter(lambda p: p.is_dir(), [Path(p) for p in [path, *opt["fallbacks"]]]), None
    )
    if folder is None:
        return None
    return {
        "folder": str(folder),
        "items": [gen_item(p) for p in folder.glob("*") if path_filter(p)],
    }
get_folder_list.default_opt = {"only_dir": True, "fallbacks": []}

jrpc.add_method(M.read_wallpaper_config)
jrpc.add_method(M.write_wallpaper_config)
jrpc.add_method(M.reset_wallpaper_config)
jrpc.add_method(M.delete_wallpaper_config_key)
jrpc.add_method(M.workshop_browse)
jrpc.add_method(M.workshop_item)
jrpc.add_method(M.wallpaper_caps)
jrpc.add_method(M.resolve_resolutions)
jrpc.add_method(M.path_exists)
jrpc.add_method(M.record_last_applied)
jrpc.add_method(M.read_favorites)
jrpc.add_method(M.write_favorites)
jrpc.add_method(M.translate)
jrpc.add_method(M.steam_session_status)
jrpc.add_method(M.steam_subscribe)
jrpc.add_method(M.steam_unsubscribe)
jrpc.add_method(M.workshop_download_state)

async def connect(uri):
    async with websockets.connect(uri) as websocket:
        while True:
            recv: str = jrpc.handle(await websocket.recv())
            await websocket.send(recv)

if __name__ == "__main__":
    import argparse

    parser: argparse.ArgumentParser = argparse.ArgumentParser(
        description="qml localfile helper"
    )
    parser.add_argument("url", metavar="URL", type=str, help="a websocket url")
    args: dict = vars(parser.parse_args())

    if hasattr(asyncio, "run"):
        asyncio.run(connect(args["url"]))
    else:
        asyncio.get_event_loop().run_until_complete(connect(args["url"]))
