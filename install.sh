#!/bin/bash
# YouTube Focus Watchdog — One-command installer for macOS
# Usage: sudo bash install.sh
#
# This script:
#   1. Validates the environment (sudo, source files present)
#   2. Asks for an expiration date and validates it
#   3. Generates the CSS hash and injects the base64 payload into watchdog.sh
#   4. Writes EXPIRY_DATE and CSS_HASH into config.env
#   5. Deploys all files to their system destinations
#   6. Configures /etc/hosts and Safari preferences
#   7. Loads the LaunchDaemon and runs the watchdog once immediately

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
DEST_CONFIG="${DEST_ETC}/config.env"
DEST_WATCHDOG="/usr/local/bin/watchdog.sh"
DEST_PLIST="/Library/LaunchDaemons/com.focus.youtube.watchdog.plist"

# Daemon label (must match the Label key in the .plist)
DAEMON_LABEL="com.focus.youtube.watchdog"

# /etc/hosts block markers
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
    read -r EXPIRY_DATE

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
# Step 4 — Generate MD5 hash of the source CSS
# ---------------------------------------------------------------------------

CSS_HASH="$(md5 -q "${SRC_CSS}")"
[[ -n "$CSS_HASH" ]] || die "Failed to compute MD5 hash of ${SRC_CSS}"
success "CSS MD5 hash: ${CSS_HASH}"

# ---------------------------------------------------------------------------
# Step 5 — Base64-encode the CSS and inject it into a temp copy of watchdog.sh
# ---------------------------------------------------------------------------

# Work on a temp copy so the source file is never modified
WATCHDOG_TMP="$(mktemp /tmp/watchdog.XXXXXX.sh)"
# Ensure the temp file is cleaned up on exit (success or failure)
trap 'rm -f "${WATCHDOG_TMP}"' EXIT

cp "${SRC_WATCHDOG}" "${WATCHDOG_TMP}"

# Encode the CSS as a single-line base64 string (no line wrapping)
CSS_BASE64="$(base64 -i "${SRC_CSS}" | tr -d '\n')"
[[ -n "$CSS_BASE64" ]] || die "Failed to base64-encode ${SRC_CSS}"

# Replace the placeholder line  CSS_BASE64=""  with the real payload.
# We use a Python one-liner to do a safe literal replacement, avoiding any
# sed delimiter conflicts caused by special characters in the base64 string.
python3 - "${WATCHDOG_TMP}" "${CSS_BASE64}" <<'PYEOF'
import sys, pathlib

target = pathlib.Path(sys.argv[1])
payload = sys.argv[2]
old_line = 'CSS_BASE64=""'
new_line = f'CSS_BASE64="{payload}"'

content = target.read_text()
if old_line not in content:
    print(f"ERROR: marker '{old_line}' not found in {target}", file=sys.stderr)
    sys.exit(1)

target.write_text(content.replace(old_line, new_line, 1))
PYEOF

success "CSS base64 payload injected into watchdog (temp copy)"

# ---------------------------------------------------------------------------
# Step 6 — Write EXPIRY_DATE and CSS_HASH into a temp copy of config.env
# ---------------------------------------------------------------------------

CONFIG_TMP="$(mktemp /tmp/config.XXXXXX.env)"
trap 'rm -f "${WATCHDOG_TMP}" "${CONFIG_TMP}"' EXIT

cp "${SRC_CONFIG}" "${CONFIG_TMP}"

# Replace the EXPIRY_DATE value
python3 - "${CONFIG_TMP}" "EXPIRY_DATE" "${EXPIRY_DATE}" <<'PYEOF'
import sys, re, pathlib

target = pathlib.Path(sys.argv[1])
key    = sys.argv[2]
value  = sys.argv[3]

content = target.read_text()
# Match:  KEY="anything"  or  KEY=anything  (with optional trailing comment)
pattern = rf'^({re.escape(key)}=")[^"]*(")'
replacement = rf'\g<1>{value}\2'
new_content, n = re.subn(pattern, replacement, content, count=1, flags=re.MULTILINE)
if n == 0:
    print(f"ERROR: key '{key}' not found in {target}", file=sys.stderr)
    sys.exit(1)
target.write_text(new_content)
PYEOF

# Replace the CSS_HASH value
python3 - "${CONFIG_TMP}" "CSS_HASH" "${CSS_HASH}" <<'PYEOF'
import sys, re, pathlib

target = pathlib.Path(sys.argv[1])
key    = sys.argv[2]
value  = sys.argv[3]

content = target.read_text()
pattern = rf'^({re.escape(key)}=")[^"]*(")'
replacement = rf'\g<1>{value}\2'
new_content, n = re.subn(pattern, replacement, content, count=1, flags=re.MULTILINE)
if n == 0:
    print(f"ERROR: key '{key}' not found in {target}", file=sys.stderr)
    sys.exit(1)
target.write_text(new_content)
PYEOF

success "EXPIRY_DATE and CSS_HASH written into config.env (temp copy)"

# ---------------------------------------------------------------------------
# Step 7 — Create destination directory and deploy the CSS file
# ---------------------------------------------------------------------------

if [[ ! -d "${DEST_ETC}" ]]; then
    step "Create ${DEST_ETC}" mkdir -p "${DEST_ETC}"
fi

# Remove immutable flag if the CSS already exists (re-install scenario)
if [[ -f "${DEST_CSS}" ]]; then
    chflags nouchg "${DEST_CSS}" 2>/dev/null || true
fi

step "Copy youtube-focus.css to ${DEST_ETC}" cp "${SRC_CSS}" "${DEST_CSS}"

# ---------------------------------------------------------------------------
# Step 8 — Apply immutable flag on the deployed CSS
# ---------------------------------------------------------------------------

step "Apply chflags uchg on CSS" chflags uchg "${DEST_CSS}"

# ---------------------------------------------------------------------------
# Step 9 — Deploy the modified watchdog.sh
# ---------------------------------------------------------------------------

step "Copy watchdog.sh to ${DEST_WATCHDOG}" cp "${WATCHDOG_TMP}" "${DEST_WATCHDOG}"

# ---------------------------------------------------------------------------
# Step 10 — Set executable permissions on watchdog.sh
# ---------------------------------------------------------------------------

step "chmod 755 watchdog.sh" chmod 755 "${DEST_WATCHDOG}"

# ---------------------------------------------------------------------------
# Step 11 — Deploy the modified config.env
# ---------------------------------------------------------------------------

step "Copy config.env to ${DEST_ETC}" cp "${CONFIG_TMP}" "${DEST_CONFIG}"

# ---------------------------------------------------------------------------
# Step 12 — Deploy the LaunchDaemon plist
# ---------------------------------------------------------------------------

step "Copy .plist to ${DEST_PLIST}" cp "${SRC_PLIST}" "${DEST_PLIST}"

# ---------------------------------------------------------------------------
# Step 13 — Set correct ownership on the plist
# ---------------------------------------------------------------------------

step "chown root:wheel on .plist" chown root:wheel "${DEST_PLIST}"

# ---------------------------------------------------------------------------
# Step 14 — Set correct permissions on the plist
# ---------------------------------------------------------------------------

step "chmod 644 on .plist" chmod 644 "${DEST_PLIST}"

# ---------------------------------------------------------------------------
# Step 15 — Write /etc/hosts entries
# ---------------------------------------------------------------------------

# Source HOSTS_DOMAINS from the temp config (it is a bash array)
# shellcheck source=/dev/null
source "${CONFIG_TMP}"

# Remove any pre-existing block in case this is a re-install, then append fresh entries.
# We use a Python one-liner to strip everything between the markers (inclusive).
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

# Build the new block and append it
{
    printf '\n%s\n' "${HOSTS_MARKER_BEGIN}"
    for domain in "${HOSTS_DOMAINS[@]}"; do
        printf '0.0.0.0 %s\n' "${domain}"
    done
    printf '%s\n' "${HOSTS_MARKER_END}"
} >> /etc/hosts

success "/etc/hosts entries written (${#HOSTS_DOMAINS[@]} domains)"

# Flush DNS so the new entries take effect immediately
dscacheutil -flushcache
killall -HUP mDNSResponder 2>/dev/null || true
success "DNS cache flushed"

# ---------------------------------------------------------------------------
# Step 16 — Configure Safari preferences
# ---------------------------------------------------------------------------

# Determine the real (non-root) user who invoked sudo so we write prefs into
# their home directory, not root's.  Fall back to root if unavailable.
REAL_USER="${SUDO_USER:-root}"

# Use domain name (not path) so macOS resolves the sandboxed container automatically.
# This requires Full Disk Access for the terminal — if it fails, the watchdog will
# retry every 5 minutes once FDA is granted.
if sudo -u "${REAL_USER}" defaults write com.apple.Safari UserStyleSheetEnabled -bool true 2>/dev/null \
&& sudo -u "${REAL_USER}" defaults write com.apple.Safari UserStyleSheetLocationURLString "file://${DEST_CSS}" 2>/dev/null; then
    success "Safari preferences configured for user '${REAL_USER}'"
else
    warn "Could not write Safari preferences — your terminal needs Full Disk Access"
    warn "Go to: System Settings → Privacy & Security → Full Disk Access → enable your terminal"
    warn "The watchdog will configure Safari automatically once FDA is granted"
fi

# ---------------------------------------------------------------------------
# Step 17 — Load the LaunchDaemon (handle re-install gracefully)
# ---------------------------------------------------------------------------

# If the daemon is already loaded, unload it first before re-loading.
if launchctl list "${DAEMON_LABEL}" &>/dev/null; then
    info "Daemon already loaded — unloading first"
    launchctl bootout system "${DEST_PLIST}" 2>/dev/null || \
        launchctl bootout system/"${DAEMON_LABEL}" 2>/dev/null || true
fi

step "Load daemon with launchctl bootstrap" \
    launchctl bootstrap system "${DEST_PLIST}"

success "LaunchDaemon '${DAEMON_LABEL}' loaded and will start at every boot"

# ---------------------------------------------------------------------------
# Step 18 — Run watchdog.sh once immediately
# ---------------------------------------------------------------------------

info "Running watchdog.sh once immediately..."
if /bin/bash "${DEST_WATCHDOG}"; then
    success "Initial watchdog run completed"
else
    warn "Initial watchdog run exited with a non-zero status (check /var/log/youtube-focus.log)"
fi

# ---------------------------------------------------------------------------
# Step 19 — Summary
# ---------------------------------------------------------------------------

printf '\n'
printf '\033[1;32m========================================\033[0m\n'
printf '\033[1;32m  YouTube Focus Watchdog — Installed\033[0m\n'
printf '\033[1;32m========================================\033[0m\n'
printf '\n'
printf '  Expiration date  : %s (%d days)\n' "${EXPIRY_DATE}" "${days_until}"
printf '  CSS MD5 hash     : %s\n' "${CSS_HASH}"
printf '\n'
printf '  Deployed files:\n'
printf '    %-45s  %s\n' "${DEST_CSS}"       "immutable (uchg)"
printf '    %-45s  %s\n' "${DEST_WATCHDOG}"  "chmod 755"
printf '    %-45s  %s\n' "${DEST_CONFIG}"    "config"
printf '    %-45s  %s\n' "${DEST_PLIST}"     "root:wheel 644"
printf '\n'
printf '  /etc/hosts       : %d domains blocked\n' "${#HOSTS_DOMAINS[@]}"
printf '  Safari prefs     : UserStyleSheetEnabled=true\n'
printf '  LaunchDaemon     : %s\n' "${DAEMON_LABEL}"
printf '  Log              : /var/log/youtube-focus.log\n'
printf '\n'
printf '  The watchdog runs every 2 minutes and self-heals any tampering.\n'
printf '  To monitor: tail -f /var/log/youtube-focus.log\n'
printf '\n'
