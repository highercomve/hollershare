#!/usr/bin/env bash
# Private display and D-Bus for HollerShare GUI tests. No user desktop access.
set -euo pipefail
if [[ -z ${ORIEL_HEADLESS_INNER:-} ]]; then
    exec env -u WAYLAND_DISPLAY -u DISPLAY GDK_BACKEND=x11 NO_AT_BRIDGE=1 GTK_A11Y=none \
        ORIEL_HEADLESS_INNER=1 dbus-run-session -- xvfb-run -a -s '-screen 0 1024x768x24' "$0" "$@"
fi
exec "$@"
