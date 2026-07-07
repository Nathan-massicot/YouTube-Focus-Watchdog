#!/bin/bash
# YouTube Focus Watchdog — self-healing enforcement script.
# Launched by launchd ONLY when a watched file changes (WatchPaths), plus one
# safety-net pass every 5 minutes — never on a tight polling loop, so it adds
# zero load while videos play. Each check repairs only when drift is found.

# ---------------------------------------------------------------------------
# Config loading — next to this script first, then the system-wide path
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/config.env"
elif [[ -f /usr/local/etc/youtube-focus/config.env ]]; then
    # shellcheck source=/dev/null
    source /usr/local/etc/youtube-focus/config.env
else
    exit 1
fi

# Immutable backup of the stylesheet, deployed beside the live file by
# install.sh. It is the restore source: comparing against it replaces the old
# MD5 hash, so there is no hash to keep in sync. Never watched, never written
# at runtime — only read.
CSS_BACKUP="$(dirname "$CSS_PATH")/.youtube-focus.css.bak"

# ---------------------------------------------------------------------------
# check_expiry — exit silently once EXPIRY_DATE (the temporal variable) passed
# ---------------------------------------------------------------------------
check_expiry() {
    # Fail closed: a missing or malformed EXPIRY_DATE keeps enforcement active
    [[ "${EXPIRY_DATE:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
    if [[ "$(date '+%Y%m%d')" -gt "${EXPIRY_DATE//-/}" ]]; then
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# check_css — restore the live CSS from the immutable backup when it is missing
# or differs (tampered). cmp against the backup is the integrity check.
# ---------------------------------------------------------------------------
check_css() {
    [[ -f "$CSS_BACKUP" ]] || return 1            # nothing to restore from
    [[ -d "$(dirname "$CSS_PATH")" ]] || mkdir -p "$(dirname "$CSS_PATH")"

    if [[ ! -f "$CSS_PATH" ]] || ! cmp -s "$CSS_PATH" "$CSS_BACKUP"; then
        chflags nouchg "$CSS_PATH" 2>/dev/null
        cp "$CSS_BACKUP" "$CSS_PATH"
    fi
}

# ---------------------------------------------------------------------------
# check_immutability — keep the uchg (user immutable) flag on the live CSS
# ---------------------------------------------------------------------------
check_immutability() {
    [[ -f "$CSS_PATH" ]] || return 0
    [[ "$(stat -f '%Sf' "$CSS_PATH" 2>/dev/null)" == *uchg* ]] || chflags uchg "$CSS_PATH"
}

# ---------------------------------------------------------------------------
# check_safari_prefs — ensure each user's Safari points at our stylesheet.
# Runs `defaults` inside the user's GUI login session (launchctl asuser)
# because com.apple.Safari is sandboxed: a bare `sudo -u` from a root daemon
# does not reach the per-user container. Works only while the user is logged
# in — which is fine, there is nothing to enforce when nobody is browsing.
# If a preference had to be repaired, quit and relaunch that user's Safari so
# the stylesheet takes effect again.
# ---------------------------------------------------------------------------
check_safari_prefs() {
    local expected_url="file://${CSS_PATH}"
    local user_home username uid plist_path changed

    # as_user CMD... — run CMD in the loop's current user login session.
    # Relies on bash dynamic scope to read uid/username.
    as_user() { launchctl asuser "$uid" sudo -u "$username" "$@"; }

    for user_home in /Users/*/; do
        username="$(basename "$user_home")"
        [[ "$username" == "Shared" || "$username" == ".localized" ]] && continue

        # No Safari container plist means this user never ran Safari
        plist_path="${user_home}${SAFARI_CONTAINER_RELATIVE}"
        [[ -f "$plist_path" ]] || continue

        uid="$(id -u "$username" 2>/dev/null)" || continue
        changed=false

        if [[ "$(as_user defaults read com.apple.Safari UserStyleSheetEnabled 2>/dev/null)" != "1" ]]; then
            as_user defaults write com.apple.Safari UserStyleSheetEnabled -bool true 2>/dev/null && changed=true
        fi

        if [[ "$(as_user defaults read com.apple.Safari UserStyleSheetLocationURLString 2>/dev/null)" != "$expected_url" ]]; then
            as_user defaults write com.apple.Safari UserStyleSheetLocationURLString "$expected_url" 2>/dev/null && changed=true
        fi

        # Quit ONLY this user's Safari when a pref was repaired, wait for it to
        # exit, then relaunch it so browsing resumes with the stylesheet on.
        if [[ "$changed" == true ]] && pgrep -u "$username" -x Safari &>/dev/null; then
            pkill -u "$username" -x Safari 2>/dev/null
            for _ in {1..10}; do
                pgrep -u "$username" -x Safari &>/dev/null || break
                sleep 0.5
            done
            as_user open -a Safari 2>/dev/null
        fi
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_expiry
check_css
check_immutability
check_safari_prefs

exit 0
