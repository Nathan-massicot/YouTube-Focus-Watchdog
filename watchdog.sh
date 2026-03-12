#!/bin/bash
# YouTube Focus Watchdog — Self-healing monitoring script
# Runs every 5 minutes as root via a macOS LaunchDaemon.
# Ensures the CSS stylesheet, Safari preferences, and /etc/hosts entries
# remain intact for the duration of the blocking period.

# ---------------------------------------------------------------------------
# CSS base64 payload — REPLACED BY INSTALL.SH
# install.sh will inject the real base64-encoded content of youtube-focus.css
# into this variable before deploying the script.
# ---------------------------------------------------------------------------
CSS_BASE64=""

# ---------------------------------------------------------------------------
# Config loading
# Look for config.env next to this script first, then at the system-wide path.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_LOCAL="${SCRIPT_DIR}/config.env"
CONFIG_SYSTEM="/usr/local/etc/youtube-focus/config.env"

if [[ -f "$CONFIG_LOCAL" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_LOCAL"
elif [[ -f "$CONFIG_SYSTEM" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_SYSTEM"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: config.env not found (checked $CONFIG_LOCAL and $CONFIG_SYSTEM)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# log MESSAGE — write a timestamped line to $LOG_PATH and to stderr
log() {
    local message="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] ${message}" | tee -a "$LOG_PATH" >&2
}

# ---------------------------------------------------------------------------
# check_expiry — compare today's date with EXPIRY_DATE
# Returns 0 if the block is still active, exits 0 if it has expired.
# ---------------------------------------------------------------------------
check_expiry() {
    local today
    today="$(date '+%Y-%m-%d')"

    # Convert dates to comparable integers by stripping dashes (YYYYMMDD)
    local today_int expiry_int
    today_int="${today//-/}"
    expiry_int="${EXPIRY_DATE//-/}"

    if [[ "$today_int" -gt "$expiry_int" ]]; then
        log "Block expired (expiry was $EXPIRY_DATE), skipping enforcement"
        exit 0
    fi

    # Calculate remaining days using macOS date arithmetic
    local today_epoch expiry_epoch days_remaining
    today_epoch="$(date -j -f '%Y-%m-%d' "$today" '+%s' 2>/dev/null)"
    expiry_epoch="$(date -j -f '%Y-%m-%d' "$EXPIRY_DATE" '+%s' 2>/dev/null)"
    days_remaining=$(( (expiry_epoch - today_epoch) / 86400 ))

    log "Expiry check: $EXPIRY_DATE, OK (${days_remaining} days remaining)"
}

# ---------------------------------------------------------------------------
# check_css — ensure the CSS file exists and has not been tampered with
# ---------------------------------------------------------------------------
check_css() {
    local css_dir
    css_dir="$(dirname "$CSS_PATH")"

    # Ensure the parent directory exists
    if [[ ! -d "$css_dir" ]]; then
        mkdir -p "$css_dir"
        log "CSS check: created missing directory $css_dir"
    fi

    # Restore from embedded base64 if the file is missing
    if [[ ! -f "$CSS_PATH" ]]; then
        if [[ -z "$CSS_BASE64" ]]; then
            log "CSS check: ERROR — file missing and CSS_BASE64 is empty, cannot restore"
            return 1
        fi
        echo "$CSS_BASE64" | base64 --decode > "$CSS_PATH"
        log "CSS check: RESTORED (file was missing)"
        return 0
    fi

    # File exists — verify its integrity against the reference MD5 hash.
    # If CSS_HASH is empty (install.sh has not set it yet), skip integrity check.
    if [[ -z "$CSS_HASH" ]]; then
        log "CSS check: OK (no reference hash configured, skipping integrity check)"
        return 0
    fi

    local current_hash
    current_hash="$(md5 -q "$CSS_PATH" 2>/dev/null)"

    if [[ "$current_hash" != "$CSS_HASH" ]]; then
        if [[ -z "$CSS_BASE64" ]]; then
            log "CSS check: ERROR — hash mismatch but CSS_BASE64 is empty, cannot restore"
            return 1
        fi
        # Remove the immutable flag temporarily so we can overwrite the file
        chflags nouchg "$CSS_PATH" 2>/dev/null
        echo "$CSS_BASE64" | base64 --decode > "$CSS_PATH"
        log "CSS check: RESTORED (hash mismatch — expected $CSS_HASH, got $current_hash)"
    else
        log "CSS check: OK"
    fi
}

# ---------------------------------------------------------------------------
# check_immutability — ensure the CSS file carries the uchg (user immutable) flag
# ---------------------------------------------------------------------------
check_immutability() {
    if [[ ! -f "$CSS_PATH" ]]; then
        log "Immutability check: SKIPPED (CSS file does not exist)"
        return 1
    fi

    # ls -lO on macOS prints file flags in the permissions column area.
    # We look for the literal string "uchg" in that output.
    local ls_output
    ls_output="$(ls -lO "$CSS_PATH" 2>/dev/null)"

    if echo "$ls_output" | grep -q "uchg"; then
        log "Immutability check: OK"
    else
        chflags uchg "$CSS_PATH"
        log "Immutability check: RESTORED (uchg flag was missing, reapplied)"
    fi
}

# ---------------------------------------------------------------------------
# check_safari_prefs — ensure Safari is configured to use our stylesheet
# ---------------------------------------------------------------------------
check_safari_prefs() {
    local expected_url="file://${CSS_PATH}"
    local needs_flush=false

    # Resolve the sandboxed Safari plist path for each real (non-root) user
    # The watchdog runs as root, so we find actual users with a home in /Users
    local user_home plist_path
    for user_home in /Users/*/; do
        local username
        username="$(basename "$user_home")"
        # Skip system-like directories
        [[ "$username" == "Shared" || "$username" == ".localized" ]] && continue

        plist_path="${user_home}${SAFARI_CONTAINER_RELATIVE}"
        # If the container plist doesn't exist, this user hasn't run Safari
        [[ -f "$plist_path" ]] || continue

        # --- UserStyleSheetEnabled ---
        # Use domain name (not path) so macOS resolves the sandboxed container
        local enabled
        enabled="$(sudo -u "${username}" defaults read com.apple.Safari UserStyleSheetEnabled 2>/dev/null)"

        if [[ "$enabled" != "1" ]]; then
            if sudo -u "${username}" defaults write com.apple.Safari UserStyleSheetEnabled -bool true 2>/dev/null; then
                log "Safari prefs check: RESTORED UserStyleSheetEnabled for ${username} (was '${enabled:-missing}')"
                needs_flush=true
            else
                log "Safari prefs check: FAILED to write UserStyleSheetEnabled for ${username} (Full Disk Access required)"
            fi
        fi

        # --- UserStyleSheetLocationURLString ---
        local current_url
        current_url="$(sudo -u "${username}" defaults read com.apple.Safari UserStyleSheetLocationURLString 2>/dev/null)"

        if [[ "$current_url" != "$expected_url" ]]; then
            if sudo -u "${username}" defaults write com.apple.Safari UserStyleSheetLocationURLString "$expected_url" 2>/dev/null; then
                log "Safari prefs check: RESTORED UserStyleSheetLocationURLString for ${username} (was '${current_url:-missing}')"
                needs_flush=true
            else
                log "Safari prefs check: FAILED to write UserStyleSheetLocationURLString for ${username} (Full Disk Access required)"
            fi
        fi
    done

    if [[ "$needs_flush" == true ]]; then
        # Force-kill Safari so it reloads with the restored stylesheet.
        # Without this, the user could keep browsing with the CSS disabled.
        if pgrep -x Safari &>/dev/null; then
            killall Safari 2>/dev/null
            log "Safari prefs check: Safari force-quit to apply restored preferences"
        fi
    else
        log "Safari prefs check: OK"
    fi
}

# ---------------------------------------------------------------------------
# check_hosts — ensure every blocked domain is present in /etc/hosts
# ---------------------------------------------------------------------------
check_hosts() {
    local hosts_file="/etc/hosts"
    local any_added=false

    for domain in "${HOSTS_DOMAINS[@]}"; do
        # Use a word-boundary-aware grep to avoid partial matches
        if ! grep -qE "^[[:space:]]*0\.0\.0\.0[[:space:]]+${domain}([[:space:]]|$)" "$hosts_file"; then
            echo "0.0.0.0 ${domain}" >> "$hosts_file"
            log "Hosts check: RESTORED 0.0.0.0 ${domain}"
            any_added=true
        fi
    done

    if [[ "$any_added" == false ]]; then
        log "Hosts check: OK"
    fi
}

# ---------------------------------------------------------------------------
# flush_dns — clear the macOS DNS resolver cache
# ---------------------------------------------------------------------------
flush_dns() {
    dscacheutil -flushcache
    killall -HUP mDNSResponder 2>/dev/null
    log "DNS flushed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "Watchdog started"

check_expiry      # exits 0 if the block period has ended
check_css
check_immutability
check_safari_prefs
check_hosts
flush_dns

log "Watchdog completed"
