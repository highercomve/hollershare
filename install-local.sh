#!/usr/bin/env bash
# Build and install HollerShare for the current Linux user, without sudo.
set -euo pipefail

usage() {
    printf 'Usage: %s [--skip-build] [-D<zig build option>...]\n' "$0"
    printf 'Environment: ORIEL_FORK=/path/to/oriel builds against that checkout (requires an Oriel CLI with --fork support).\n'
}

skip_build=false
build_flags=()
for argument in "$@"; do
    case "$argument" in
        --skip-build) skip_build=true ;;
        -D*) build_flags+=("$argument") ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

if [[ $(uname -s) != Linux ]]; then
    printf 'This installer requires Linux (.desktop launchers).\n' >&2
    exit 1
fi

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd -- "$project_dir"
if ! "$skip_build"; then
    if [[ -n ${ORIEL_FORK:-} ]]; then
        fork_dir=$(cd -- "$ORIEL_FORK" && pwd)
        if [[ ! -f "$fork_dir/build.zig" || ! -f "$fork_dir/build.zig.zon" ]]; then
            printf 'ORIEL_FORK must point to an Oriel checkout with build.zig and build.zig.zon.\n' >&2
            exit 1
        fi
        # Match GhostPen: let Oriel select the dependency and its Zig version,
        # rather than changing the project's build.zig.zon.
        if ! command -v oriel >/dev/null 2>&1; then
            printf 'ORIEL_FORK requires an Oriel CLI with --fork support. Update the Oriel CLI and retry.\n' >&2
            exit 1
        fi
        oriel build --fork="$fork_dir" -Doptimize=ReleaseSafe -Dnative_ui "${build_flags[@]}"
    else
        zig build -Doptimize=ReleaseSafe -Dnative_ui "${build_flags[@]}"
    fi
fi

source_binary="$project_dir/zig-out/bin/hollershare"
if [[ ! -x "$source_binary" || ! -f "$project_dir/assets/brand/hollershare-icon.png" ]]; then
    printf 'Missing HollerShare binary or icon. Run this script without --skip-build.\n' >&2
    exit 1
fi

app_id=dev.hollershare.App
bin_dir="$HOME/.local/bin"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"
desktop_dir="$data_dir/applications"
icon_root="$data_dir/icons/hicolor"
installed_binary="$bin_dir/hollershare"
desktop_file="$desktop_dir/$app_id.desktop"
case "$installed_binary$data_dir" in
    *$'\n'*|*$'\r'*) printf 'Installation paths must not contain line breaks.\n' >&2; exit 1 ;;
esac

mkdir -p -- "$bin_dir" "$desktop_dir"
staging_dir=$(mktemp -d "$bin_dir/.hollershare-install.XXXXXX")
trap 'rm -rf -- "$staging_dir"' EXIT
install -m 755 -- "$source_binary" "$staging_dir/hollershare"

# Launcher icons for every standard hicolor size, rendered from the SVG so
# small sizes stay sharp. Falls back to the shipped 1024px PNG alone.
if command -v rsvg-convert >/dev/null 2>&1 && [[ -f "$project_dir/assets/brand/hollershare-icon.svg" ]]; then
    for size in 16 24 32 48 64 128 256 512 1024; do
        mkdir -p -- "$staging_dir/icons/${size}x${size}"
        rsvg-convert -w "$size" -h "$size" "$project_dir/assets/brand/hollershare-icon.svg" \
            -o "$staging_dir/icons/${size}x${size}/$app_id.png" || exit 1
    done
    mkdir -p -- "$staging_dir/icons/scalable"
    install -m 644 -- "$project_dir/assets/brand/hollershare-icon.svg" "$staging_dir/icons/scalable/$app_id.svg"
else
    mkdir -p -- "$staging_dir/icons/1024x1024"
    install -m 644 -- "$project_dir/assets/brand/hollershare-icon.png" "$staging_dir/icons/1024x1024/$app_id.png"
fi

# Escape the Exec argument, then the desktop-entry string. Percent signs
# must be doubled so paths containing them are not interpreted as field codes.
exec_path=${installed_binary//\\/\\\\}
exec_path=${exec_path//\"/\\\"}
exec_path=${exec_path//\$/\\\$}
exec_path=${exec_path//\`/\\\`}
exec_path=${exec_path//%/%%}
exec_path=${exec_path//\\/\\\\}
try_exec_path=${installed_binary//\\/\\\\}
cat > "$staging_dir/$app_id.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=HollerShare
GenericName=Local File Sharing
Comment=Share files with computers and Android Quick Share
Exec="$exec_path"
TryExec=$try_exec_path
Icon=$app_id
Terminal=false
StartupNotify=true
StartupWMClass=$app_id
Categories=Network;FileTransfer;
Keywords=files;sharing;Quick Share;Android;LAN;
EOF
chmod 644 "$staging_dir/$app_id.desktop"

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$staging_dir/$app_id.desktop"
fi
# Renaming the staged binary also permits updating a running installation.
mv -f -- "$staging_dir/hollershare" "$installed_binary"
for staged_icon_dir in "$staging_dir"/icons/*/; do
    size=${staged_icon_dir##*/icons/}
    icon_dir="$icon_root/${size%/}/apps"
    mkdir -p -- "$icon_dir"
    mv -f -- "$staged_icon_dir/$app_id".* "$icon_dir/"
done
mv -f -- "$staging_dir/$app_id.desktop" "$desktop_file"

# Replace launchers from the previous application name. Downloaded files
# and the user's configuration are preserved.
for previous_name in ghostshare ghostfile; do
    rm -f -- "$desktop_dir/dev.$previous_name.App.desktop" "$bin_dir/$previous_name"
    find "$icon_root" -name "dev.$previous_name.App.*" -delete 2>/dev/null || true
done

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$desktop_dir" || printf 'Could not refresh the desktop database.\n' >&2
fi
# Always refresh: a stale user-local icon-theme.cache hides the icon even
# though the PNGs are installed. Without an index.theme there is nothing to
# refresh, so drop the stale cache and let toolkits scan the directories.
if command -v gtk-update-icon-cache >/dev/null 2>&1 && [[ -d "$icon_root" ]]; then
    if ! gtk-update-icon-cache -q -f "$icon_root" 2>/dev/null; then
        rm -f -- "$icon_root/icon-theme.cache"
    fi
fi

printf 'Installed %s\nDesktop launcher: %s\n' "$installed_binary" "$desktop_file"
printf 'Open HollerShare from your application menu or run %s\n' "$installed_binary"
