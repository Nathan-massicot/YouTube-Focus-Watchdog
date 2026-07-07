#!/bin/bash
# YouTube Focus Watchdog — One-command installer for macOS
# Usage: sudo bash install.sh
#
# This script:
#   1. Validates the environment (sudo, source files present)
#   2. Asks for an expiration date and validates it
#   3. Deploys the CSS (live + immutable backup), watchdog, config, and plist
#   4. Adds each user's Safari prefs plist to the daemon's WatchPaths
#   5. Configures Safari preferences and loads the event-driven LaunchDaemon

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Directory that contains install.sh and all source files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source files (read-only; we never modify them directly)
SRC_CSS="${SCRIPT_DIR}/youtube-focus.css"
SRC_WATCHDOG="${SCRIPT_DIR}/watchdog.sh"
SRC_CONFIG="${SCRIPT_DIR}/config.env"
SRC_PLIST="${SCRIPT_DIR}/com.focus.youtube.watchdog.plist"

# System destinations
DEST_ETC="/usr/local/etc/youtube-focus"
DEST_CSS="${DEST_ETC}/youtube-focus.css"
DEST_CSS_BACKUP="${DEST_ETC}/.youtube-focus.css.bak"
DEST_CONFIG="${DEST_ETC}/config.env"
DEST_WATCHDOG="/usr/local/bin/watchdog.sh"
DEST_PLIST="/Library/LaunchDaemons/com.focus.youtube.watchdog.plist"

# Daemon label (must match the Label key in the .plist)
DAEMON_LABEL="com.focus.youtube.watchdog"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Print a coloured status line
info()    { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
die()     { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# step DESCRIPTION COMMAND... — run a command and report pass/fail
step() {
    local description="$1"
    shift
    if "$@"; then
        success "${description}"
    else
        die "${description} — command failed: $*"
    fi
}

# ---------------------------------------------------------------------------
# Step 1 — Verify sudo
# ---------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root. Try: sudo bash install.sh"
fi

info "Running as root — OK"

# ---------------------------------------------------------------------------
# Step 2 — Verify source files are present
# ---------------------------------------------------------------------------

for f in "$SRC_CSS" "$SRC_WATCHDOG" "$SRC_CONFIG" "$SRC_PLIST"; do
    [[ -f "$f" ]] || die "Required source file not found: $f"
done

success "All source files found"

# ---------------------------------------------------------------------------
# Step 3 — Ask for expiration date
# ---------------------------------------------------------------------------

EXPIRY_DATE=""

while true; do
    printf '\nEnter the blocking expiration date (format YYYY-MM-DD): '
    # `|| die` guards against EOF/piped stdin, which would otherwise make `read`
    # return non-zero and silently abort the whole script under `set -e`.
    read -r EXPIRY_DATE || die "No input received — run this installer interactively: sudo bash install.sh"

    # Validate format with a simple regex
    if [[ ! "$EXPIRY_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        warn "Invalid format. Expected YYYY-MM-DD (e.g. 2026-09-01). Please try again."
        continue
    fi

    # Validate that the date is a real calendar date (macOS date -j)
    if ! date -j -f '%Y-%m-%d' "$EXPIRY_DATE" '+%s' &>/dev/null; then
        warn "Date '$EXPIRY_DATE' is not a valid calendar date. Please try again."
        continue
    fi

    # Validate that the date is strictly in the future
    today_epoch="$(date -j -f '%Y-%m-%d' "$(date '+%Y-%m-%d')" '+%s')"
    expiry_epoch="$(date -j -f '%Y-%m-%d' "$EXPIRY_DATE" '+%s')"

    if [[ "$expiry_epoch" -le "$today_epoch" ]]; then
        warn "Date '$EXPIRY_DATE' is today or in the past. The expiration date must be in the future."
        continue
    fi

    break
done

days_until=$(( (expiry_epoch - today_epoch) / 86400 ))
success "Expiration date set to ${EXPIRY_DATE} (${days_until} days from today)"

# ---------------------------------------------------------------------------
# Step 4 — Build the deployed config.env
# EXPIRY_DATE is the only templated value; it was validated as YYYY-MM-DD
# above, so it is safe to drop into the sed replacement. No python needed.
# ---------------------------------------------------------------------------

CONFIG_TMP=""; PLIST_TMP=""
trap 'rm -f "${CONFIG_TMP}" "${PLIST_TMP}"' EXIT

CONFIG_TMP="$(mktemp /tmp/config.env.XXXXXX)"
cp "${SRC_CONFIG}" "${CONFIG_TMP}"
sed -i '' -E "s|^EXPIRY_DATE=\"[^\"]*\"|EXPIRY_DATE=\"${EXPIRY_DATE}\"|" "${CONFIG_TMP}"
grep -q "^EXPIRY_DATE=\"${EXPIRY_DATE}\"" "${CONFIG_TMP}" \
    || die "Failed to write EXPIRY_DATE into config.env"

success "EXPIRY_DATE written into config.env (temp copy)"

# ---------------------------------------------------------------------------
# Step 5 — Deploy the stylesheet: a live copy Safari loads + an immutable
# backup the watchdog restores from. Both root-owned and locked with uchg.
# ---------------------------------------------------------------------------

if [[ ! -d "${DEST_ETC}" ]]; then
    step "Create ${DEST_ETC}" mkdir -p "${DEST_ETC}"
fi

# Unlock any pre-existing immutable copies (re-install scenario)
for f in "${DEST_CSS}" "${DEST_CSS_BACKUP}"; do
    if [[ -f "$f" ]]; then chflags nouchg "$f" 2>/dev/null || true; fi
done

step "Copy youtube-focus.css to ${DEST_CSS}"        cp "${SRC_CSS}" "${DEST_CSS}"
step "Copy backup stylesheet to ${DEST_CSS_BACKUP}" cp "${SRC_CSS}" "${DEST_CSS_BACKUP}"
step "Apply chflags uchg on live CSS"               chflags uchg "${DEST_CSS}"
step "Apply chflags uchg on backup CSS"             chflags uchg "${DEST_CSS_BACKUP}"

# ---------------------------------------------------------------------------
# Step 6 — Deploy watchdog.sh verbatim (no payload injection: the immutable
# backup above is the restore source, so the deployed script == the repo file).
# ---------------------------------------------------------------------------

step "Copy watchdog.sh to ${DEST_WATCHDOG}" cp "${SRC_WATCHDOG}" "${DEST_WATCHDOG}"
step "chmod 755 watchdog.sh"                chmod 755 "${DEST_WATCHDOG}"

# ---------------------------------------------------------------------------
# Step 7 — Deploy config.env
# ---------------------------------------------------------------------------

step "Copy config.env to ${DEST_CONFIG}" cp "${CONFIG_TMP}" "${DEST_CONFIG}"

# ---------------------------------------------------------------------------
# Step 8 — Deploy the LaunchDaemon plist
# The plist is event-driven (WatchPaths): launchd starts the watchdog only
# when a watched file changes. Here we append each user's sandboxed Safari
# preferences plist to WatchPaths so that toggling the stylesheet off in
# Safari triggers an immediate repair. The path is added for EVERY home in
# /Users — even if the plist does not exist yet (launchd arms the watch when
# the file appears, e.g. after that account's first Safari launch). Accounts
# created after install need a re-run of install.sh for instant repair; until
# then the 5-minute safety net covers them. The relative path must mirror
# SAFARI_CONTAINER_RELATIVE in config.env.
# ---------------------------------------------------------------------------

PLIST_TMP="$(mktemp /tmp/watchdog.plist.XXXXXX)"
cp "${SRC_PLIST}" "${PLIST_TMP}"

python3 - "${PLIST_TMP}" /Users/*/ <<'PYEOF'
import sys, plistlib, pathlib

target = pathlib.Path(sys.argv[1])
rel = 'Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist'

with target.open('rb') as f:
    plist = plistlib.load(f)

watch = plist.setdefault('WatchPaths', [])
added = 0
for home in sys.argv[2:]:
    home_path = pathlib.Path(home.rstrip('/'))
    if home_path.name in ('Shared', '.localized') or not home_path.is_dir():
        continue
    p = str(home_path / rel)
    if p not in watch:
        watch.append(p)
        added += 1

with target.open('wb') as f:
    plistlib.dump(plist, f)
print(f"      Safari preference plists watched for {added} user account(s)")
PYEOF

success "Safari preference plists added to WatchPaths"

step "Copy .plist to ${DEST_PLIST}" cp "${PLIST_TMP}" "${DEST_PLIST}"
step "chown root:wheel on .plist"   chown root:wheel "${DEST_PLIST}"
step "chmod 644 on .plist"          chmod 644 "${DEST_PLIST}"

# ---------------------------------------------------------------------------
# Step 9 — Legacy /etc/hosts cleanup
# Older versions DNS-blocked the avatar CDN here; this version does not touch
# /etc/hosts at all (the CSS already greys avatars). Strip any stale block so
# upgrading installs leave /etc/hosts clean.
# ---------------------------------------------------------------------------

if grep -qF '# BEGIN YouTube Focus' /etc/hosts 2>/dev/null; then
    sed -i '' '/# BEGIN YouTube Focus/,/# END YouTube Focus/d' /etc/hosts
    dscacheutil -flushcache || true
    killall -HUP mDNSResponder 2>/dev/null || true
    success "Removed legacy /etc/hosts block (no longer used)"
fi

# ---------------------------------------------------------------------------
# Step 10 — Configure Safari preferences
# ---------------------------------------------------------------------------

# Determine the real (non-root) user who invoked sudo so we write prefs into
# their session, not root's.  Fall back to root if unavailable.
REAL_USER="${SUDO_USER:-root}"
REAL_UID="$(id -u "${REAL_USER}" 2>/dev/null || echo '')"

# Write inside the user's login session (launchctl asuser) so the sandboxed
# com.apple.Safari container is reached — a bare `sudo -u` from root does not.
# This is only a head start for the installing account; the watchdog re-applies
# these prefs for whichever user is logged in (e.g. your dedicated Focus
# account) whenever they drift, so a failure here is harmless.
if [[ -n "${REAL_UID}" ]] \
&& launchctl asuser "${REAL_UID}" sudo -u "${REAL_USER}" defaults write com.apple.Safari UserStyleSheetEnabled -bool true 2>/dev/null \
&& launchctl asuser "${REAL_UID}" sudo -u "${REAL_USER}" defaults write com.apple.Safari UserStyleSheetLocationURLString "file://${DEST_CSS}" 2>/dev/null; then
    success "Safari preferences configured for user '${REAL_USER}'"
else
    warn "Could not pre-configure Safari for '${REAL_USER}' (not in a GUI session?) — harmless:"
    warn "the watchdog sets UserStyleSheetEnabled automatically for any logged-in user."
fi

# ---------------------------------------------------------------------------
# Step 11 — Load the LaunchDaemon (handle re-install gracefully)
# ---------------------------------------------------------------------------

# If the daemon is already loaded, unload it first before re-loading.
if launchctl list "${DAEMON_LABEL}" &>/dev/null; then
    info "Daemon already loaded — unloading first"
    launchctl bootout system "${DEST_PLIST}" 2>/dev/null || \
        launchctl bootout system/"${DAEMON_LABEL}" 2>/dev/null || true
fi

# Bootstrap right after a bootout can fail transiently — retry briefly
daemon_loaded=false
for _ in 1 2 3; do
    if launchctl bootstrap system "${DEST_PLIST}" 2>/dev/null; then
        daemon_loaded=true
        break
    fi
    sleep 1
done
if [[ "${daemon_loaded}" == true ]]; then
    success "Load daemon with launchctl bootstrap"
else
    die "Load daemon with launchctl bootstrap — command failed: launchctl bootstrap system ${DEST_PLIST}"
fi

success "LaunchDaemon '${DAEMON_LABEL}' loaded — event-driven, starts at every boot"

# ---------------------------------------------------------------------------
# Step 12 — Run watchdog.sh once immediately
# ---------------------------------------------------------------------------

info "Running watchdog.sh once immediately..."
if /bin/bash "${DEST_WATCHDOG}"; then
    success "Initial watchdog run completed"
else
    warn "Initial watchdog run exited with a non-zero status"
fi

# ---------------------------------------------------------------------------
# Step 13 — Summary
# ---------------------------------------------------------------------------

printf '\n'
printf '\033[1;32m========================================\033[0m\n'
printf '\033[1;32m  YouTube Focus Watchdog — Installed\033[0m\n'
printf '\033[1;32m========================================\033[0m\n'
printf '\n'
printf '  Expiration date  : %s (%d days)\n' "${EXPIRY_DATE}" "${days_until}"
printf '\n'
printf '  Deployed files:\n'
printf '    %-48s  %s\n' "${DEST_CSS}"        "immutable (uchg)"
printf '    %-48s  %s\n' "${DEST_CSS_BACKUP}" "immutable backup (uchg)"
printf '    %-48s  %s\n' "${DEST_WATCHDOG}"   "chmod 755"
printf '    %-48s  %s\n' "${DEST_CONFIG}"     "config"
printf '    %-48s  %s\n' "${DEST_PLIST}"      "root:wheel 644"
printf '\n'
printf '  Safari prefs     : UserStyleSheetEnabled=true\n'
printf '  LaunchDaemon     : %s\n' "${DAEMON_LABEL}"
printf '\n'
printf '  The watchdog is event-driven: it reacts instantly when a protected\n'
printf '  file changes and is otherwise completely idle (5-min safety net).\n'
printf '\n'
printf '\033[1;33m  IMPORTANT — to make the block hard to disable:\033[0m\n'
printf '    Do your browsing in a STANDARD (non-admin) macOS account.\n'
printf '    There you cannot stop the daemon or unlock the CSS.\n'
printf '    In that account, set the stylesheet once via:\n'
printf '      Safari → Settings → Advanced → Style sheet → Other… → %s\n' "${DEST_CSS}"
printf '    Keep your admin account for administration only.\n'
printf '\n'
