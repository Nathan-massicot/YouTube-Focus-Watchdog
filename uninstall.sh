#!/bin/bash
# YouTube Full Focus — Uninstaller for macOS
# Usage: sudo bash uninstall.sh
#
# This script:
#   1. Validates the environment (sudo)
#   2. Reads the expiration date from config.env
#   3. Blocks uninstallation if the expiry date has not yet passed
#   4. Unloads and removes the LaunchDaemon
#   5. Removes the CSS (live + backup, after stripping the immutable flag)
#   6. Removes watchdog.sh and config.env
#   7. Resets Safari preferences for every account
#   8. Removes any legacy /etc/hosts block left by older versions

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths  (must mirror install.sh exactly)
# ---------------------------------------------------------------------------

DEST_ETC="/usr/local/etc/youtube-focus"
DEST_CSS="${DEST_ETC}/youtube-focus.css"
DEST_CSS_BACKUP="${DEST_ETC}/.youtube-focus.css.bak"
DEST_CONFIG="${DEST_ETC}/config.env"
DEST_WATCHDOG="/usr/local/bin/watchdog.sh"
DEST_PLIST="/Library/LaunchDaemons/com.focus.youtube.watchdog.plist"

DAEMON_LABEL="com.focus.youtube.watchdog"

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
    die "config.env not found at ${DEST_CONFIG} — is YouTube Full Focus actually installed?"
fi

# Source only the EXPIRY_DATE variable; avoid executing arbitrary code
EXPIRY_DATE=""
# Capture only the quoted value; `.*` after the closing quote swallows any
# trailing comment (config.env keeps a comment on the EXPIRY_DATE line).
EXPIRY_DATE="$(grep -E '^EXPIRY_DATE=' "${DEST_CONFIG}" | head -1 | sed -E 's/^EXPIRY_DATE="([^"]*)".*/\1/')"

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
    printf '  The block is active through %s; uninstallation unlocks the day after.\n' "${EXPIRY_DATE}"
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
# Step 6 — Remove the immutable flag from the CSS files, then delete them
# (both the live stylesheet and the immutable backup)
# ---------------------------------------------------------------------------

for css in "${DEST_CSS}" "${DEST_CSS_BACKUP}"; do
    if [[ -f "$css" ]]; then
        chflags nouchg "$css" 2>/dev/null || true
        remove_file "$css"
    else
        warn "$css not found — already removed, skipping"
    fi
done

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
# Step 9 — Remove any legacy /etc/hosts block
# Older versions DNS-blocked the avatar CDN here; current versions do not use
# /etc/hosts at all. Strip the block (and flush DNS once) if an old install
# left one behind.
# ---------------------------------------------------------------------------

if grep -qF '# BEGIN YouTube Focus' /etc/hosts 2>/dev/null; then
    sed -i '' '/# BEGIN YouTube Focus/,/# END YouTube Focus/d' /etc/hosts
    dscacheutil -flushcache || true
    killall -HUP mDNSResponder 2>/dev/null || true
    success "/etc/hosts — legacy block removed (DNS flushed)"
else
    info "/etc/hosts — no legacy block found, nothing to clean"
fi

# ---------------------------------------------------------------------------
# Step 10 — Reset Safari preferences for EVERY user the watchdog enforced
# (the watchdog loops over /Users/*, so the uninstall must too — not just
# the admin running this script). Writes go through launchctl asuser so the
# sandboxed Safari container is reached; best-effort for logged-out users.
# ---------------------------------------------------------------------------

SAFARI_CONTAINER_RELATIVE="Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"

info "Resetting Safari preferences for all users..."

prefs_reset=0
for user_home in /Users/*/; do
    username="$(basename "${user_home}")"
    [[ "${username}" == "Shared" || "${username}" == ".localized" ]] && continue
    [[ -f "${user_home}${SAFARI_CONTAINER_RELATIVE}" ]] || continue
    uid="$(id -u "${username}" 2>/dev/null)" || continue

    launchctl asuser "${uid}" sudo -u "${username}" defaults write com.apple.Safari UserStyleSheetEnabled -bool false 2>/dev/null || true
    launchctl asuser "${uid}" sudo -u "${username}" defaults delete com.apple.Safari UserStyleSheetLocationURLString 2>/dev/null || true
    success "Safari preferences reset for user '${username}'"
    prefs_reset=$((prefs_reset + 1))
done

if [[ "${prefs_reset}" -eq 0 ]]; then
    warn "No Safari UserStyleSheet prefs found — nothing to reset"
    warn "If the stylesheet is still active somewhere, turn it off in Safari → Settings → Advanced."
fi

# ---------------------------------------------------------------------------
# Step 11 — Summary
# ---------------------------------------------------------------------------

printf '\n'
printf '\033[1;32m========================================\033[0m\n'
printf '\033[1;32m  YouTube Full Focus — Uninstalled\033[0m\n'
printf '\033[1;32m========================================\033[0m\n'
printf '\n'
printf '  Removed files:\n'
printf '    %s\n' "${DEST_CSS}"
printf '    %s\n' "${DEST_CSS_BACKUP}"
printf '    %s\n' "${DEST_WATCHDOG}"
printf '    %s\n' "${DEST_CONFIG}"
printf '    %s\n' "${DEST_ETC}"
printf '    %s\n' "${DEST_PLIST}"
printf '\n'
printf '  Safari prefs     : UserStyleSheetEnabled=false (all users, best-effort)\n'
printf '  LaunchDaemon     : %s unloaded and deleted\n' "${DAEMON_LABEL}"
printf '\n'
printf '  YouTube is now fully unblocked. Good luck!\n'
printf '\n'
