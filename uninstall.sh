#!/bin/bash
# Removes everything netlock put on this Mac: pf rules if still loaded, the
# installed commands, ~/.config/netlock, and the netallow group that older
# versions created. Running apps are untouched. Run without sudo.
set -e
GROUP=netallow
home=$(dscl . -read "/Users/${SUDO_USER:-$USER}" NFSHomeDirectory | awk '{print $2}')

if pgrep -f '(^|[ /])netlock( |$)' >/dev/null; then
  echo "netlock is running. Stop it first (Ctrl+C in its terminal), then rerun." >&2
  exit 1
fi

sudo -v
if sudo pfctl -s rules 2>/dev/null | grep -q '^anchor "netlock"'; then
  sudo pfctl -q -f /etc/pf.conf 2>/dev/null || true
  sudo pfctl -q -a netlock -F rules 2>/dev/null || true
  sudo pfctl -q -d 2>/dev/null || true
  echo "pf: netlock rules removed, default config loaded, pf disabled"
fi
if dscl . -read "/Groups/$GROUP" >/dev/null 2>&1; then
  sudo dscl . -delete "/Groups/$GROUP"
  echo "group $GROUP (from an older netlock version) removed"
fi
sudo rm -f /usr/local/bin/netlock /usr/local/bin/netlock-apps
echo "removed /usr/local/bin/netlock and /usr/local/bin/netlock-apps"
rm -rf "$home/.config/netlock"
echo "removed $home/.config/netlock"
echo "done. This repo folder is untouched."
