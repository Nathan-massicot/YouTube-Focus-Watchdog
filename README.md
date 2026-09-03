# YouTube Full Focus

**Get your time back without missing what you really like.**

A self-healing macOS system that removes YouTube **recommendations, Shorts, and
recommendation thumbnails** in Safari — without blocking videos, search, or
subscriptions. Enforcement is automatic, persistent, and time-limited by a root
LaunchDaemon that reacts the moment a protected file changes (launchd file
watches) and stays completely idle otherwise — zero overhead while you browse.

> **You do not need a separate account.** Install the watchdog and it blocks
> recommendations in whatever account you browse from — that is the whole product.
> The only catch: because you administer this Mac, you can also turn the block off
> yourself. If stopping *yourself* from doing that matters to you, there is one
> optional step (browsing from a Standard, non-admin account), described in
> [Optional: make it hard to disable yourself](#optional-make-it-hard-to-disable-yourself).

**[⬇ Download YouTube Full Focus for macOS](https://github.com/Nathan-massicot/YouTube-Focus-Watchdog/releases/latest/download/YouTube-Full-Focus.dmg)**
 · [Download page](https://nathan-massicot.github.io/YouTube-Focus-Watchdog/)
 · macOS 13+ · Apple Silicon and Intel

The app is a thin front end over the scripts in this repository: it picks the end
date, asks for your administrator password once, and runs the very same
`install.sh` / `uninstall.sh`. Everything below works identically from a terminal
if you prefer.

---

## Features

- **CSS injection** — hides the homepage grid, recommended titles/metadata,
  recommendation thumbnails, the Up Next sidebar, end screens, the topic filter
  bar, Shorts, and channel avatars directly in Safari.
- **Search stays usable** — search-result **thumbnails and durations are shown**
  so an intentional search still works; only the recommendation surfaces are
  hidden.
- **Immutable CSS file + backup** — the live stylesheet and a backup copy are
  both locked with `chflags uchg`; neither can be deleted or overwritten without
  root, and the watchdog restores the live file from the backup if it drifts.
- **Safari restart on tampering** — if the user stylesheet preference is
  changed, the watchdog restores it, quits *that user's* Safari, and relaunches
  it so the stylesheet takes effect again.
- **Expiration timer** — you set an end date at install time; the watchdog stops
  enforcing after that date and uninstallation becomes possible.
- **Event-driven LaunchDaemon** — launchd starts the root watchdog only when a
  protected file changes (`WatchPaths`), plus one safety-net pass every 5
  minutes. No polling, no induced latency while videos play.

---

## Optional: make it hard to disable yourself

**This section is entirely optional.** The watchdog already blocks recommendations
in your normal account — if that is all you want, skip this. Read on only if you
want to stop *yourself* from turning the block off. Two facts shape what is
possible:

1. Safari's user-stylesheet setting is a **per-user preference you can always
   toggle** in *Safari → Settings → Advanced*. No personal-Mac mechanism can grey
   it out permanently without either erasing the Mac (MDM supervision) or removing
   your admin rights. (This was verified against macOS 26 behavior.)
2. Therefore the watchdog does not pretend to be un-disableable. It re-applies
   the block as soon as the change hits disk (launchd watches the preference
   file) — and the strength comes from **where you browse**.

**Browse in a dedicated Standard (non-admin) account.** In that account you
cannot:

- run `sudo`, so you cannot unload the LaunchDaemon;
- `chflags nouchg` / delete the immutable CSS or its backup;
- remove configuration profiles or the daemon.

The only residual bypass is toggling the stylesheet off in Safari, which the root
watchdog reverses as soon as the preference file is written (and restarts
Safari). Your Administrator account remains the acknowledged escape hatch — keep
it for administration only.

---

## What gets blocked vs. preserved

| Element | Blocked how |
|---------|-------------|
| Homepage recommendation grid | CSS |
| Recommended video titles & metadata | CSS |
| Recommendation thumbnails (home, sidebar, channel grids, playlists) | CSS (greyed) |
| Shorts shelf, nav entry, standalone page | CSS |
| Up Next sidebar on watch pages | CSS |
| End-of-video suggestion overlays | CSS |
| Topic / category filter bar | CSS |
| Channel avatars in recommendation cards | CSS |

| Preserved | Notes |
|-----------|-------|
| Search bar & results | **Thumbnails and durations shown**; result titles are hidden by CSS |
| Video player | Plays normally |
| Subscriptions feed (`/feed/subscriptions`) | Untouched |

> Want search-result **titles** visible too? Remove the `ytd-video-renderer`
> rules from section 2 of `youtube-focus.css` and re-install.

---

## Requirements

- macOS Ventura 13 or later (developed/verified on macOS 26).
- Safari (built-in).
- An Administrator account with `sudo` (for installation).
- *(Optional)* a **Standard (non-admin) account** for browsing — only if you want
  the block to be hard to disable yourself (see
  [Optional hardening](#optional-make-it-hard-to-disable-yourself)).

> **Full Disk Access (FDA) is required for the Safari-preference self-healing.**
> macOS TCC gates access to Safari's sandboxed container by the *responsible
> binary* of the daemon — `/bin/bash` — regardless of `launchctl asuser`/`sudo -u`.
> Grant it once: *System Settings → Privacy & Security → Full Disk Access →* add
> `/bin/bash` (⌘⇧G in the file picker, type `/bin/bash`). Without this grant the
> CSS file is still enforced, but a stylesheet toggle in Safari is silently never
> repaired. Re-check after macOS upgrades/migrations.

---

## Setup

### 1. Install

**Option A — the app.** Download
[`YouTube-Full-Focus.dmg`](https://github.com/Nathan-massicot/YouTube-Focus-Watchdog/releases/latest/download/YouTube-Full-Focus.dmg),
drag *YouTube Full Focus* into Applications, pick a duration and click **Activer le
blocage**. macOS asks for your administrator password once.

> **First launch is blocked by Gatekeeper.** The app is ad-hoc signed but not
> notarised — notarisation requires a paid Apple Developer account. Open it once
> (macOS refuses), then go to *System Settings → Privacy & Security*, scroll to
> Security and click **Open Anyway**. Or clear the quarantine flag yourself:
> `xattr -d com.apple.quarantine "/Applications/YouTube Full Focus.app"`.

**Option B — the command line.**
```bash
git clone https://github.com/Nathan-massicot/YouTube-Focus-Watchdog.git
cd YouTube-Focus-Watchdog
sudo bash install.sh                        # prompts for an end date
sudo bash install.sh --expiry 2026-12-01    # or set it up front, unattended
```

Either way the installer deploys the stylesheet (a live copy plus an immutable
backup), the watchdog, config, and the event-driven daemon, then runs one
enforcement pass. It also strips any leftover `/etc/hosts` block from older
versions. It depends on nothing beyond a stock macOS — no Homebrew, no Python, no
Command Line Tools.

### 2. Point Safari at the stylesheet, once
*Safari → Settings → Advanced → Style sheet → Other…* →
`/usr/local/etc/youtube-focus/youtube-focus.css`

This step is required: choosing the file via the picker grants Safari's sandbox
permission to **load** it. The watchdog then keeps the setting enabled.

### 3. Verify
```bash
launchctl list | grep com.focus.youtube.watchdog            # → label listed (PID is
                                                            #   usually "-": the daemon
                                                            #   only runs on file events)
ls -lO /usr/local/etc/youtube-focus/youtube-focus.css       # → "uchg" flag
ls -lO /usr/local/etc/youtube-focus/.youtube-focus.css.bak  # → backup, "uchg" flag
sudo bash /usr/local/bin/watchdog.sh                        # force one pass
```
Open `youtube.com`: the homepage is empty, **search shows thumbnails**,
recommendations are gone. Toggle the stylesheet off → the watchdog re-enables
it and restarts Safari within seconds.

**That's it — recommendations are blocked.** To *also* make the block hard to turn
off yourself, do steps 2–3 inside a Standard (non-admin) account instead — see
[Optional hardening](#optional-make-it-hard-to-disable-yourself).

---

## Uninstallation

In the app, click **Retirer** — it is greyed out until the period ends. From a
terminal:

```bash
sudo bash uninstall.sh
```

Refused until your expiration date has passed (the block is active *through* that
date and unlocks the day after). Once allowed, it unloads/removes the daemon,
strips the immutable flag and deletes the CSS (live + backup), removes
`watchdog.sh` and config, resets Safari preferences for every account
(best-effort), and removes any legacy `/etc/hosts` block from older versions.

---

## How it works

```
macOS Boot
  └── launchd loads com.focus.youtube.watchdog (LaunchDaemon, root)
        └── watchdog.sh runs when launchd sees a watched file change
            (the CSS, its directory, or a user's Safari preferences plist),
            plus once every 5 minutes as a safety net
              1. Check expiration date — exit silently if it has passed
              2. Live CSS present and matches the immutable backup (cmp) —
                 else restore it by copying the backup over it
              3. CSS carries the uchg immutable flag — reapply if missing
              4. For each logged-in user (via launchctl asuser, to reach the
                 sandboxed container): ensure UserStyleSheetEnabled=true and
                 the correct path — if changed, restore, then quit and
                 relaunch that user's Safari
```

The stylesheet is deployed twice: a live copy Safari loads and an immutable
backup the watchdog restores from, so it recovers even if the live file is
deleted. The watchdog runs silently and keeps no log files. Between file-change
events it does not run at all — there is no background activity that could
interfere with video playback.

---

## Deployed file locations

| File | Path | Notes |
|------|------|-------|
| CSS stylesheet (live) | `/usr/local/etc/youtube-focus/youtube-focus.css` | locked with `uchg` |
| CSS stylesheet (backup) | `/usr/local/etc/youtube-focus/.youtube-focus.css.bak` | locked with `uchg`; restore source |
| Watchdog script | `/usr/local/bin/watchdog.sh` | `chmod 755`, deployed verbatim from the repo |
| Configuration | `/usr/local/etc/youtube-focus/config.env` | expiry date + paths |
| LaunchDaemon plist | `/Library/LaunchDaemons/com.focus.youtube.watchdog.plist` | `root:wheel`, `644`, `WatchPaths` + 5-min safety net |

---

## Configuration (`config.env`)

| Key | Meaning |
|-----|---------|
| `EXPIRY_DATE` | `YYYY-MM-DD`; enforcement stops the day after this date |
| `CSS_PATH` | Absolute path of the deployed stylesheet (the backup lives beside it as `.youtube-focus.css.bak`) |
| `SAFARI_CONTAINER_RELATIVE` | Path of each user's sandboxed Safari prefs plist, relative to their home |

---

## Known limitations

| Limitation | Reality / mitigation |
|------------|----------------------|
| The stylesheet toggle is per-user and cannot be permanently locked on a personal Mac | Browse in a Standard account; the watchdog re-enables it as soon as the preference file is written (worst case: the 5-minute safety net if a write event is missed). Requires the FDA grant (see Requirements). |
| Deleting `~/Library/Containers/com.apple.Safari` defeats the stylesheet silently | A Standard user owns their container; deleting it wipes the sandbox grant that lets Safari *load* the CSS. The watchdog rewrites the preferences and reads them back green, but Safari never applies the stylesheet until the picker step is redone. Costs the user their Safari history/settings. |
| Accounts created **after** install only get the 5-minute safety net for toggle repair | `WatchPaths` is frozen at install time. Re-run `sudo bash install.sh` after creating a new account to restore instant repair. |
| You are the Administrator | From an admin account you can always disable the system (unload the daemon, unlock the CSS). The Standard-account model is the whole point. A true lock would require erasing the Mac (MDM supervision). |
| macOS Safe Mode disables LaunchDaemons | Full access is possible in Safe Mode. |
| YouTube changes its DOM | Some CSS selectors may stop matching; update `youtube-focus.css` and re-install. |
| `uninstall.sh` is in the repo | Anyone with `sudo` can run it before expiry; delete it after install if you want to remove that path. |

---

## Building from source

`build.sh` produces the universal app bundle and the disk image. It needs only
the Xcode Command Line Tools (`xcode-select --install`) — no full Xcode, no
third-party tooling, and no binary assets in the repository (the icon is rendered
from `app/make-icon.swift` at build time).

```bash
./build.sh                 # → dist/YouTube Full Focus.app and dist/YouTube-Full-Focus-<version>.dmg
SKIP_DMG=1 ./build.sh      # app bundle only
```

Layout:

| Path | Role |
|------|------|
| `app/Sources/` | SwiftUI front end (window, status probing, privileged runner) |
| `app/make-icon.swift` | Renders `AppIcon.icns` with CoreGraphics |
| `build.sh` | Compiles arm64 + x86_64, assembles the bundle, ad-hoc signs, builds the DMG |
| `docs/` | The download page, served by GitHub Pages |
| `VERSION` | Single source of truth for the version number |

The app embeds the shell project under `Contents/Resources/payload/` and runs it
through `osascript … with administrator privileges`; it contains no enforcement
logic of its own.

**Releasing.** Bump `VERSION`, commit, then push a matching tag:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

`.github/workflows/release.yml` builds on a macOS runner, checks the bundle is
signed, universal and dependency-free, and attaches both
`YouTube-Full-Focus-<version>.dmg` and the stable `YouTube-Full-Focus.dmg` (which the
download page links to) to a new GitHub Release.

**Publishing the download page.** In *Settings → Pages*, set the source to the
`main` branch and the `/docs` folder.

---

## License

MIT — see [LICENSE](LICENSE).
