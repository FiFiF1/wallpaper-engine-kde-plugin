# wekde-crashguard

Self-heal watchdog for Wallpaper Engine scenes that hard-crash plasmashell.
These files are versioned here for easy revert; the **live** copies are installed
elsewhere:

| Repo file | Installed to |
|-----------|--------------|
| `wekde-crashguard` | `~/.local/bin/wekde-crashguard` (chmod +x) |
| `wekde-crashguard.service` | `~/.config/systemd/user/wekde-crashguard.service` |

## Reinstall from this repo

```sh
install -m755 _crashguard/wekde-crashguard ~/.local/bin/wekde-crashguard
install -m644 _crashguard/wekde-crashguard.service ~/.config/systemd/user/wekde-crashguard.service
systemctl --user daemon-reload
systemctl --user enable --now wekde-crashguard.service
```

## What it does

Polls for plasma-plasmashell entering `failed` state, then disables the single
most-likely crashing wallpaper (breadcrumb → last-applied → journal), shows an
error card on that monitor, logs to `~/.local/share/wekde/crash-log.jsonl`, and
restarts plasmashell. After the 4th consecutive crash it disables all scenes.

- Status / recent crashes: `wekde-crashguard --status`
- Dry-run against a config copy: `wekde-crashguard --dry-run DIR`
- Recover once without restarting: `wekde-crashguard --no-restart`

State lives under `~/.local/share/wekde/` (blocklist, crash log, error cards,
breadcrumbs) and is intentionally **not** in this repo.
