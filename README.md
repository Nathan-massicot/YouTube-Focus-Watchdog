# YouTube Focus Watchdog

A self-healing macOS system that removes YouTube recommendations, Shorts, and
thumbnails in Safari — without blocking access to videos, search, or
subscriptions. Enforcement is automatic, persistent, and time-limited.

---

## Features

- **CSS injection** — hides the homepage grid, Up Next sidebar, end screens,
  topic filter bar, and channel avatars directly in Safari
- **DNS blocking** — redirects YouTube thumbnail CDNs (`i.ytimg.com`, etc.) to
  `0.0.0.0` via `/etc/hosts`, preventing images from loading at the network
  level
- **Immutable CSS file** — the stylesheet is locked with `chflags uchg` so it
  cannot be deleted or overwritten without root access
- **Safari force-quit on tampering** — if the watchdog detects that Safari
  preferences have been changed, it force-quits Safari so the restored
  stylesheet takes effect immediately
- **Expiration timer** — you set an end date at install time; the watchdog
  stops enforcing after that date and uninstallation becomes possible
- **Self-healing LaunchDaemon** — a root-level daemon runs every 2 minutes from
  boot and restores any component that has gone missing or been modified

---

## What Gets Blocked

| Element | Method |
|---------|--------|
| Homepage recommendation grid | CSS |
| Recommended video titles and metadata | CSS |
| Thumbnails | CSS + DNS (i.ytimg.com, yt3.ggpht.com, …) |
| Shorts shelf, navigation entry, standalone page | CSS |
| Up Next sidebar on video pages | CSS |
| End-of-video suggestion overlays | CSS |
| Topic / category filter bar | CSS |
| Channel avatars in recommendation cards | CSS |

## What Is Preserved

- Search bar and search results (titles hidden, but links work)
- Video player — videos play normally
- Subscriptions feed (`/feed/subscriptions`)

---

## Requirements

- macOS Ventura 13 or later
- Safari (built-in)
- Administrator account with `sudo` access
- Terminal with **Full Disk Access** granted (required for Safari preferences)
  — go to System Settings > Privacy & Security > Full Disk Access

---

## Installation

```bash
git clone https://github.com/Nathan-massicot/YouTube-Focus-Watchdog.git
cd YouTube-Focus-Watchdog
sudo bash install.sh
```

The installer will:

1. Prompt you for an expiration date (`YYYY-MM-DD`)
2. Generate an MD5 hash of the CSS and embed it in the watchdog
3. Deploy all files to their system locations
4. Write `/etc/hosts` entries and flush DNS
5. Configure Safari preferences
6. Load the LaunchDaemon and run one immediate enforcement pass

**If your terminal does not have Full Disk Access**, Safari preferences will not
be written during installation but the watchdog will configure them
automatically on the next cycle once FDA is granted.

---

## Uninstallation

```bash
sudo bash uninstall.sh
```

Uninstallation is blocked until the expiration date you set has passed. Once
allowed, the script removes all deployed files, cleans `/etc/hosts`, resets
Safari preferences, and flushes DNS.

---

## How It Works

```
macOS Boot
  └── launchd loads com.focus.youtube.watchdog (LaunchDaemon)
        └── watchdog.sh runs every 2 minutes as root
              1. Check expiration date — exit silently if expired
              2. Verify CSS file exists and hash matches — restore from
                 embedded base64 payload if not
              3. Verify CSS carries the uchg immutable flag — reapply if missing
              4. Verify Safari UserStyleSheetEnabled and path — restore and
                 force-quit Safari if either has been changed
              5. Verify /etc/hosts entries — re-add any missing domain
              6. Flush DNS cache (dscacheutil + mDNSResponder)
```

The CSS payload is base64-encoded into `watchdog.sh` at install time, so the
watchdog can restore the stylesheet even if the source file is deleted.

---

## Deployed File Locations

| File | Path | Notes |
|------|------|-------|
| CSS stylesheet | `/usr/local/etc/youtube-focus/youtube-focus.css` | locked with `uchg` |
| Watchdog script | `/usr/local/bin/watchdog.sh` | chmod 755 |
| Configuration | `/usr/local/etc/youtube-focus/config.env` | expiry date, CSS hash |
| LaunchDaemon plist | `/Library/LaunchDaemons/com.focus.youtube.watchdog.plist` | root:wheel 644 |
| Log file | `/var/log/youtube-focus.log` | appended on each run |

To monitor activity in real time:

```bash
tail -f /var/log/youtube-focus.log
```

---

## Known Limitations

| Limitation | Impact |
|------------|--------|
| CSS can be disabled in Safari Settings | Watchdog restores it within 2 minutes and force-quits Safari |
| macOS Safe Mode disables LaunchDaemons | Full YouTube access possible in Safe Mode |
| A VPN may bypass `/etc/hosts` | Thumbnails may load when connected to a VPN |
| YouTube periodically changes its DOM structure | Some CSS selectors may stop matching; a manual CSS update is required |
| `uninstall.sh` is accessible if the repo path is known | Script can be run before expiry by anyone with sudo; consider removing it after install |

---

## License

MIT — see [LICENSE](LICENSE).
