#!/bin/bash
# YouTube Focus Watchdog — Uninstaller for macOS
# Usage: sudo bash uninstall.sh
#
# This script:
#   1. Validates the environment (sudo)
#   2. Reads the expiration date from config.env
#   3. Blocks uninstallation if the expiry date has not yet passed
#   4. Unloads and removes the LaunchDaemon
#   5. Removes the CSS (after stripping the immutable flag)
#   6. Removes watchdog.sh and config.env
#   7. Cleans /etc/hosts of the YouTube Focus block
#   8. Resets Safari preferences
#   9. Flushes DNS

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths  (must mirror install.sh exactly)
# ---------------------------------------------------------------------------

DEST_ETC="/usr/local/etc/youtube-focus"
DEST_CSS="${DEST_ETC}/youtube-focus.css"
DEST_CONFIG="${DEST_ETC}/config.env"
DEST_WATCHDOG="/usr/local/bin/watchdog.sh"
DEST_PLIST="/Library/LaunchDaemons/com.focus.youtube.watchdog.plist"

DAEMON_LABEL="com.focus.youtube.watchdog"

# /etc/hosts block markers (must match install.sh)
HOSTS_MARKER_BEGIN="# BEGIN YouTube Focus"
HOSTS_MARKER_END="# END YouTube Focus"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Print a coloured status line
info()    { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
die()     { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# remove_file PATH — remove a file, or warn if already gone
remove_file() {
    local path="$1"
    if [[ -f "$path" ]]; then
        rm -f "$path"
        success "Deleted ${path}"
    else
        warn "${path} not found — already removed, skipping"
    fi
}

# remove_dir PATH — remove a directory if it exists and is empty-ish
remove_dir() {
    local path="$1"
    if [[ -d "$path" ]]; then
        rm -rf "$path"
        success "Deleted directory ${path}"
    else
        warn "Directory ${path} not found — already removed, skipping"
    fi
}

# ---------------------------------------------------------------------------
# Step 1 — Verify sudo
# ---------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root. Try: sudo bash uninstall.sh"
fi

info "Running as root — OK"

# ---------------------------------------------------------------------------
# Step 2 — Read expiration date from config.env
# ---------------------------------------------------------------------------

if [[ ! -f "${DEST_CONFIG}" ]]; then
    die "config.env not found at ${DEST_CONFIG} — is YouTube Focus actually installed?"
fi

# Source only the EXPIRY_DATE variable; avoid executing arbitrary code
EXPIRY_DATE=""
EXPIRY_DATE="$(grep -E '^EXPIRY_DATE=' "${DEST_CONFIG}" | head -1 | sed 's/^EXPIRY_DATE="\(.*\)"/\1/')"

if [[ -z "${EXPIRY_DATE}" ]]; then
    die "Could not read EXPIRY_DATE from ${DEST_CONFIG}"
fi

info "Expiration date read from config.env: ${EXPIRY_DATE}"

# ---------------------------------------------------------------------------
# Step 3 — Block uninstallation if the expiry date has not yet passed
# ---------------------------------------------------------------------------

today_epoch="$(date -j -f '%Y-%m-%d' "$(date '+%Y-%m-%d')" '+%s')"
expiry_epoch="$(date -j -f '%Y-%m-%d' "${EXPIRY_DATE}" '+%s' 2>/dev/null)" \
    || die "EXPIRY_DATE '${EXPIRY_DATE}' in config.env is not a valid date."

if [[ "${today_epoch}" -le "${expiry_epoch}" ]]; then
    days_remaining=$(( (expiry_epoch - today_epoch) / 86400 ))
    printf '\n'
    printf '\033[1;31m========================================\033[0m\n'
    printf '\033[1;31m  Uninstallation blocked\033[0m\n'
    printf '\033[1;31m========================================\033[0m\n'
    printf '\n'
    printf '  The blocking period has not expired yet.\n'
    printf '  Expiration date  : %s\n' "${EXPIRY_DATE}"
    printf '  Days remaining   : %d\n' "${days_remaining}"
    printf '\n'
    printf '  Uninstallation will be allowed on or after %s.\n' "${EXPIRY_DATE}"
    printf '\n'
    exit 1
fi

success "Expiration date ${EXPIRY_DATE} has passed — proceeding with uninstallation"

# ---------------------------------------------------------------------------
# Step 4 — Unload the LaunchDaemon
# ---------------------------------------------------------------------------

if launchctl list "${DAEMON_LABEL}" &>/dev/null; then
    info "Stopping and unloading daemon '${DAEMON_LABEL}'..."
    launchctl bootout system "${DEST_PLIST}" 2>/dev/null \
        || launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null \
        || true
    success "Daemon '${DAEMON_LABEL}' unloaded"
else
    warn "Daemon '${DAEMON_LABEL}' is not loaded — skipping unload"
fi

# ---------------------------------------------------------------------------
# Step 5 — Delete the LaunchDaemon plist
# ---------------------------------------------------------------------------

remove_file "${DEST_PLIST}"

# ---------------------------------------------------------------------------
# Step 6 — Remove the immutable flag from the CSS, then delete it
# ---------------------------------------------------------------------------

if [[ -f "${DEST_CSS}" ]]; then
    chflags nouchg "${DEST_CSS}" || true
    success "Immutable flag (uchg) removed from ${DEST_CSS}"
    remove_file "${DEST_CSS}"
else
    warn "${DEST_CSS} not found — already removed, skipping"
fi

# ---------------------------------------------------------------------------
# Step 7 — Delete watchdog.sh
# ---------------------------------------------------------------------------

remove_file "${DEST_WATCHDOG}"

# ---------------------------------------------------------------------------
# Step 8 — Delete config.env and the youtube-focus directory
# ---------------------------------------------------------------------------

remove_file "${DEST_CONFIG}"
remove_dir  "${DEST_ETC}"

# ---------------------------------------------------------------------------
# Step 9 — Clean /etc/hosts
# ---------------------------------------------------------------------------

if grep -qF "${HOSTS_MARKER_BEGIN}" /etc/hosts 2>/dev/null; then
    python3 - /etc/hosts "${HOSTS_MARKER_BEGIN}" "${HOSTS_MARKER_END}" <<'PYEOF'
import sys, pathlib

hosts_path   = pathlib.Path(sys.argv[1])
marker_begin = sys.argv[2]
marker_end   = sys.argv[3]

lines = hosts_path.read_text().splitlines(keepends=True)
filtered = []
inside = False
for line in lines:
    if line.strip() == marker_begin:
        inside = True
        continue
    if line.strip() == marker_end:
        inside = False
        continue
    if not inside:
        filtered.append(line)

hosts_path.write_text(''.join(filtered))
PYEOF
    success "/etc/hosts — YouTube Focus block removed"
else
    warn "/etc/hosts — no YouTube Focus block found, skipping"
fi

# ---------------------------------------------------------------------------
# Step 10 — Reset Safari preferences
# ---------------------------------------------------------------------------

# Use the real (non-root) user who invoked sudo so we write into their
# home directory, not root's.  Fall back to root if unavailable.
REAL_USER="${SUDO_USER:-root}"

info "Resetting Safari preferences for user '${REAL_USER}'..."

if sudo -u "${REAL_USER}" defaults read com.apple.Safari UserStyleSheetEnabled &>/dev/null; then
    sudo -u "${REAL_USER}" defaults write com.apple.Safari UserStyleSheetEnabled -bool false
    sudo -u "${REAL_USER}" defaults delete com.apple.Safari UserStyleSheetLocationURLString 2>/dev/null || true
    success "Safari preferences reset for user '${REAL_USER}'"
else
    warn "No Safari UserStyleSheet preferences found — skipping reset"
fi

# ---------------------------------------------------------------------------
# Step 11 — Flush DNS
# ---------------------------------------------------------------------------

dscacheutil -flushcache
killall -HUP mDNSResponder 2>/dev/null || true
success "DNS cache flushed"

# ---------------------------------------------------------------------------
# Step 12 — Summary
# ---------------------------------------------------------------------------

printf '\n'
printf '\033[1;32m========================================\033[0m\n'
printf '\033[1;32m  YouTube Focus Watchdog — Uninstalled\033[0m\n'
printf '\033[1;32m========================================\033[0m\n'
printf '\n'
printf '  Removed files:\n'
printf '    %s\n' "${DEST_CSS}"
printf '    %s\n' "${DEST_WATCHDOG}"
printf '    %s\n' "${DEST_CONFIG}"
printf '    %s\n' "${DEST_ETC}"
printf '    %s\n' "${DEST_PLIST}"
printf '\n'
printf '  /etc/hosts       : YouTube Focus block removed\n'
printf '  Safari prefs     : UserStyleSheetEnabled=false\n'
printf '  LaunchDaemon     : %s unloaded and deleted\n' "${DAEMON_LABEL}"
printf '  DNS cache        : flushed\n'
printf '\n'
printf '  YouTube is now fully unblocked. Good luck!\n'
printf '\n'
