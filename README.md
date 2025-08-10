Important notes before running

This script is written for Debian/Ubuntu (uses apt). It will not work on macOS as-is (macOS doesn't use apt and MariaDB package management is different). If you need a macOS package, tell me and I’ll adapt.

Running this will make the MariaDB root account passwordless on that machine — do this only for local/dev use. Never do this on production/public servers.

You should run it as a user that can run sudo and provide your sudo password when asked.

To run unattended (no prompts), set env vars at top or let defaults apply.

Save this as erpnext-auto-install.sh (or erpnext-auto-install.command on macOS if you adapt it for macOS), make it executable (chmod +x erpnext-auto-install.sh) and run ./erpnext-auto-install.sh.
