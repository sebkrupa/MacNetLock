#!/bin/bash
set -e
cd "$(dirname "$0")"
sudo mkdir -p /usr/local/bin
sudo install -m 755 netlock netlock-apps /usr/local/bin/
echo "installed: /usr/local/bin/netlock, /usr/local/bin/netlock-apps"
echo "next: netlock-apps (pick apps), then: sudo netlock"
