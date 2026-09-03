#!/bin/bash
# YouTube Full Focus — One-command installer for macOS
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
# Command-line options
# The installer runs unattended when an expiration date is supplied up front —
# that is how YouTube Full Focus.app drives it, since a GUI has no stdin to prompt
# on. Without one, Step 3 falls back to the interactive prompt as before.
# ---------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
YouTube Full Focus — installer

Usage:
  sudo bash install.sh                       Interactive (prompts for the date)
  sudo bash install.sh --expiry YYYY-MM-DD   Unattended
  YTF_EXPIRY_DATE=YYYY-MM-DD sudo -E bash install.sh

Options:
  --expiry DATE   Enforcement end date, YYYY-MM-DD. Must be a real future date.
  -h, --help      Show this help and exit.
USAGE
}

# Seed from the environment so `sudo -E` / launchd-style invocations work too.
EXPIRY_DATE="${YTF_EXPIRY_DATE:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --expiry)   EXPIRY_DATE="${2:-}"; shift 2 ;;
        --expiry=*) EXPIRY_DATE="${1#*=}"; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          usage >&2; die "Unknown option: $1" ;;
    esac
done

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
# Step 3 — Determine the expiration date
# Validation is shared by both entry points: the --expiry flag (unattended,
# used by the app) and the interactive prompt. On success it exports
# today_epoch / expiry_epoch / days_until for the steps below.
# ---------------------------------------------------------------------------

# validate_expiry DATE — return 0 when DATE is a real future YYYY-MM-DD date and
# set today_epoch / expiry_epoch / days_until for the caller. On failure it sets
# VALIDATION_ERROR and returns 1. The result is deliberately NOT passed back
# through stdout: a command substitution would run this in a subshell and the
# epoch variables would never reach the caller.
VALIDATION_ERROR=""
validate_expiry() {
    local candidate="$1" normalized
    VALIDATION_ERROR=""

    if [[ ! "$candidate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        VALIDATION_ERROR="Invalid format. Expected YYYY-MM-DD (e.g. 2026-09-01)."
        return 1
    fi

    # macOS `date -j` silently rolls impossible dates over (2026-02-31 parses as
    # 2026-03-03), so parse and reformat, then insist the round trip is stable.
    if ! normalized="$(date -j -f '%Y-%m-%d' "$candidate" '+%Y-%m-%d' 2>/dev/null)" \
       || [[ "$normalized" != "$candidate" ]]; then
        VALIDATION_ERROR="Date '$candidate' is not a valid calendar date."
        return 1
    fi

    today_epoch="$(date -j -f '%Y-%m-%d' "$(date '+%Y-%m-%d')" '+%s')"
    expiry_epoch="$(date -j -f '%Y-%m-%d' "$candidate" '+%s')"

    if [[ "$expiry_epoch" -le "$today_epoch" ]]; then
        VALIDATION_ERROR="Date '$candidate' is today or in the past. The expiration date must be in the future."
        return 1
    fi

    days_until=$(( (expiry_epoch - today_epoch) / 86400 ))
    return 0
}

if [[ -n "${EXPIRY_DATE}" ]]; then
    # Unattended: a bad date is fatal, there is nobody to re-prompt.
    validate_expiry "${EXPIRY_DATE}" || die "--expiry rejected: ${VALIDATION_ERROR}"
else
    while true; do
        printf '\nEnter the blocking expiration date (format YYYY-MM-DD): '
        # `|| die` guards against EOF/piped stdin, which would otherwise make
        # `read` return non-zero and silently abort the whole script under -e.
        read -r EXPIRY_DATE || die "No input received — run this installer interactively (sudo bash install.sh) or pass --expiry YYYY-MM-DD"

        validate_expiry "${EXPIRY_DATE}" && break
        warn "${VALIDATION_ERROR} Please try again."
    done
fi
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

# mktemp created CONFIG_TMP as 0600 and cp carries that mode over. Widen it so
# YouTube Full Focus.app can read EXPIRY_DATE to display status without asking for a
# password. Root-owned and world-readable is fine: the file holds no secret,
# only the end date, and a non-root user still cannot write it.
step "chown root:wheel on config.env" chown root:wheel "${DEST_CONFIG}"
step "chmod 644 on config.env"        chmod 644 "${DEST_CONFIG}"

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

# Enumerate accounts with PlistBuddy rather than python3: on a stock Mac
# /usr/bin/python3 is a Command Line Tools stub that pops an "install developer
# tools" dialog and fails, which would break the app-driven install. PlistBuddy
# ships with every macOS.
SAFARI_CONTAINER_RELATIVE="Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"

watched=0
for user_home in /Users/*/; do
    username="$(basename "${user_home}")"
    [[ "${username}" == "Shared" || "${username}" == ".localized" ]] && continue
    [[ -d "${user_home}" ]] || continue

    watch_path="${user_home}${SAFARI_CONTAINER_RELATIVE}"

    # PLIST_TMP is a fresh copy of the repo plist (two /usr/local paths only),
    # so a user path can never already be there — checked anyway to stay
    # idempotent if the source plist ever ships one.
    if /usr/libexec/PlistBuddy -c 'Print :WatchPaths' "${PLIST_TMP}" 2>/dev/null | grep -qF "${watch_path}"; then
        continue
    fi

    /usr/libexec/PlistBuddy -c "Add :WatchPaths: string ${watch_path}" "${PLIST_TMP}" >/dev/null \
        || die "Failed to add ${watch_path} to the daemon's WatchPaths"
    watched=$(( watched + 1 ))
done

printf '      Safari preference plists watched for %d user account(s)\n' "${watched}"

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
# `do shell script … with administrator privileges` — how the app installs —
# sets no SUDO_USER, so fall back to whoever owns the console (the person at
# the GUI) before giving up and using root.
REAL_USER="${SUDO_USER:-$(stat -f '%Su' /dev/console 2>/dev/null || echo root)}"
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
printf '\033[1;32m  YouTube Full Focus — Installed\033[0m\n'
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
