#!/bin/bash
# =============================================================================
# build.sh - Build OpenMoHAA AppImage from upstream pre-built binaries
# =============================================================================
# Downloads the official OpenMoHAA release zip and packages it into a
# portable AppImage using the Anylinux-AppImages methodology.
#
# No compilation needed - much faster and more reliable than building from source.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
APP_NAME="openmohaa"
APP_PRETTY="OpenMoHAA"
UPSTREAM_REPO="openmoh/openmohaa"
ARCH=$(uname -m)

# Map uname -m to OpenMoHAA's release naming
case "$ARCH" in
    x86_64)  OPENMOHAA_ARCH="amd64" ;;
    aarch64) OPENMOHAA_ARCH="arm64" ;;
    armv7l)  OPENMOHAA_ARCH="armhf" ;;
    i686)    OPENMOHAA_ARCH="i686" ;;
    *)       OPENMOHAA_ARCH="$ARCH" ;;
esac

# Quick-sharun options
export ADD_HOOKS="${ADD_HOOKS:-}"
export UPINFO="${UPINFO:-gh-releases-zsync|${GITHUB_REPOSITORY:-${APP_NAME}}|${GITHUB_REPOSITORY_NAME:-${APP_NAME}}|latest|*${ARCH}.AppImage.zsync}"
export DEPLOY_OPENGL="${DEPLOY_OPENGL:-1}"
export DEPLOY_SDL="${DEPLOY_SDL:-1}"
export DEPLOY_PULSE="${DEPLOY_PULSE:-1}"
export DEPLOY_GLIBC="${DEPLOY_GLIBC:-1}"
export DEPLOY_LOCALE="${DEPLOY_LOCALE:-1}"
export ANYLINUX_LIB="${ANYLINUX_LIB:-1}"
export STRIP="${STRIP:-1}"
export DEBLOAT_LOCALE="${DEBLOAT_LOCALE:-1}"

# Paths
WORKDIR="${WORKDIR:-$(pwd)}"
BUILDDIR="${WORKDIR}/build_work"
ROOTFS="${BUILDDIR}/rootfs"
APPDIR="${WORKDIR}/AppDir"
DISTDIR="${WORKDIR}/dist"

# Logging
log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n'  "$*" >&2; }
err()  { printf '\033[1;31m[err]\033[0m %s\n'   "$*" >&2; }
section() { printf '\n\033[1;36m========== %s ==========\033[0m\n' "$*"; }

trap 'err "Build failed at line $LINENO (exit code: $?)"' ERR

# ---------------------------------------------------------------------------
# STEP 1: Install runtime dependencies (Arch Linux)
# ---------------------------------------------------------------------------
section "STEP 1/5: Install runtime dependencies"

# anylinux-setup-action already installed: base-devel, git, wget, patchelf,
# strace, xorg-server-xvfb, etc. We install SDL2/OpenAL runtime libs so
# quick-sharun can bundle the full dependency tree for portability.
log "Installing runtime dependencies..."
pacman -S --noconfirm --needed --overwrite '*' \
    sdl2 \
    openal \
    libvorbis \
    libogg \
    opus \
    flac \
    libmad \
    curl \
    libpulse \
    alsa-lib \
    mesa \
    glu \
    libglvnd \
    libdrm \
    wayland \
    libxkbcommon \
    libdecor \
    libx11 \
    libxext \
    libxcursor \
    libxi \
    libxfixes \
    libxrandr \
    libxss \
    libxinerama \
    libxrender \
    libxcb \
    libxau \
    libxdmcp \
    || warn "Some packages failed to install (may already be present)"

log "Verifying quick-sharun is available..."
command -v quick-sharun >/dev/null 2>&1 || {
    err "quick-sharun not found. anylinux-setup-action should have installed it."
    exit 1
}
log "  OK: quick-sharun -> $(command -v quick-sharun)"

if command -v get-debloated-pkgs >/dev/null 2>&1; then
    log "Installing debloated packages..."
    get-debloated-pkgs --add-mesa --prefer-nano   || warn "debloat mesa failed"
    get-debloated-pkgs --add-common --prefer-nano || warn "debloat common failed"
fi

# ---------------------------------------------------------------------------
# STEP 2: Download OpenMoHAA release
# ---------------------------------------------------------------------------
section "STEP 2/5: Download OpenMoHAA release"

rm -rf "$BUILDDIR" "$APPDIR" "$DISTDIR"
mkdir -p "$BUILDDIR" "$ROOTFS" "$DISTDIR"

# Determine which version to download
if [ -n "${OPENMOHAA_REF:-}" ]; then
    # User specified a ref (tag/branch/commit)
    OPENMOHAA_TAG="$OPENMOHAA_REF"
    OPENMOHAA_VERSION="$OPENMOHAA_REF"
    log "Using user-specified ref: $OPENMOHAA_VERSION"
else
    # Get latest release - use "name" field (e.g. "v0.82.1-beta") not "tag_name" (e.g. "v0.82.1")
    # OpenMoHAA uses the "-beta" suffix in release names to indicate beta status
    LATEST_RELEASE_JSON=$(curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest")

    # Use jq if available (more robust), fallback to grep
    if command -v jq >/dev/null 2>&1; then
        OPENMOHAA_TAG=$(echo "$LATEST_RELEASE_JSON" | jq -r '.tag_name // empty')
        OPENMOHAA_VERSION=$(echo "$LATEST_RELEASE_JSON" | jq -r '.name // empty')
    else
        OPENMOHAA_TAG=$(echo "$LATEST_RELEASE_JSON" | grep -oE '"tag_name": *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
        OPENMOHAA_VERSION=$(echo "$LATEST_RELEASE_JSON" | grep -oE '"name": *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
    fi

    # Fallback to tag_name if name is empty
    [ -z "$OPENMOHAA_VERSION" ] && OPENMOHAA_VERSION="$OPENMOHAA_TAG"
    log "Latest upstream version: $OPENMOHAA_VERSION (tag: $OPENMOHAA_TAG)"
fi

# Build download URL using the TAG (not the display version with -beta suffix)
DOWNLOAD_URL="https://github.com/${UPSTREAM_REPO}/releases/download/${OPENMOHAA_TAG}/openmohaa-${OPENMOHAA_TAG}-linux-${OPENMOHAA_ARCH}.zip"

log "Downloading: $DOWNLOAD_URL"
cd "$BUILDDIR"
if ! curl -fSL --retry 3 -o openmohaa.zip "$DOWNLOAD_URL"; then
    err "Failed to download from: $DOWNLOAD_URL"
    err "Check that the version '$OPENMOHAA_VERSION' exists and has a linux-${OPENMOHAA_ARCH} asset."
    exit 1
fi
log "Downloaded: $(ls -lh openmohaa.zip | awk '{print $5}')"

# Extract
log "Extracting..."
mkdir -p extracted
unzip -o openmohaa.zip -d extracted/ >/dev/null
log "Extracted files:"
ls -la extracted/

# Save version info
echo "$OPENMOHAA_VERSION" > "${WORKDIR}/LATEST_VERSION"
# Get commit hash if possible (not critical if it fails)
OPENMOHAA_COMMIT=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${UPSTREAM_REPO}/commits/main" 2>/dev/null \
    | sed -n 's/.*"sha": *"\([0-9a-f]\{12\}\).*/\1/p' | head -1 || echo "unknown")
echo "$OPENMOHAA_COMMIT" > "${WORKDIR}/LATEST_COMMIT"

# ---------------------------------------------------------------------------
# STEP 3: Install into rootfs (simulating /usr layout)
# ---------------------------------------------------------------------------
section "STEP 3/5: Install into rootfs"

# Create /usr/lib/openmohaa/ with all binaries and libs from the zip
mkdir -p "$ROOTFS/usr/lib/openmohaa"
cp -v extracted/* "$ROOTFS/usr/lib/openmohaa/"
chmod +x "$ROOTFS/usr/lib/openmohaa"/openmohaa \
         "$ROOTFS/usr/lib/openmohaa"/omohaaded \
         "$ROOTFS/usr/lib/openmohaa"/launch_openmohaa_* 2>/dev/null || true

# Create a wrapper script in /usr/bin so the .desktop file works
mkdir -p "$ROOTFS/usr/bin"
cat > "$ROOTFS/usr/bin/openmohaa" <<'WRAPPER'
#!/bin/sh
# Entrypoint wrapper for OpenMoHAA AppImage.
case "${1:-}" in
    omohaaded|launch_openmohaa_*)
        exec "/usr/lib/openmohaa/${1}" "${@:2}"
        ;;
    *)
        exec /usr/lib/openmohaa/launch_openmohaa_base "$@"
        ;;
esac
WRAPPER
chmod +x "$ROOTFS/usr/bin/openmohaa"

# Create desktop file and download the official OpenMoHAA icon
mkdir -p "$ROOTFS/usr/share/applications"
mkdir -p "$ROOTFS/usr/share/icons/hicolor/scalable/apps"

cat > "$ROOTFS/usr/share/applications/org.openmoh.openmohaa.desktop" <<DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=OpenMoHAA
Comment=Open-source Medal of Honor: Allied Assault engine
Categories=Game;Shooter;
Icon=org.openmoh.openmohaa
Exec=openmohaa
Terminal=false
X-AppImage-Name=OpenMoHAA
X-AppImage-Version=${OPENMOHAA_VERSION}
X-AppImage-Arch=${ARCH}
DESKTOP

# Download the official OpenMoHAA icon from the upstream repo
log "Downloading official OpenMoHAA icon..."
ICON_URL="https://raw.githubusercontent.com/${UPSTREAM_REPO}/main/misc/openmohaa.svg"
if curl -fSL --retry 3 -o "$ROOTFS/usr/share/icons/hicolor/scalable/apps/org.openmoh.openmohaa.svg" "$ICON_URL"; then
    log "  Downloaded official icon ($(wc -c < "$ROOTFS/usr/share/icons/hicolor/scalable/apps/org.openmoh.openmohaa.svg") bytes)"
else
    err "  WARNING: Failed to download official icon, using fallback"
    # Fallback: simple SVG if download fails
    cat > "$ROOTFS/usr/share/icons/hicolor/scalable/apps/org.openmoh.openmohaa.svg" <<'SVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <rect width="128" height="128" fill="#1a3a5c"/>
  <text x="64" y="80" font-family="sans-serif" font-size="48" font-weight="bold" text-anchor="middle" fill="#d4af37">M</text>
</svg>
SVG
fi

log "Installed files:"
find "$ROOTFS" -type f | head -20
log "Total installed size: $(du -sh "$ROOTFS" | cut -f1)"

# ---------------------------------------------------------------------------
# STEP 4: Bundle with quick-sharun + add portable hooks
# ---------------------------------------------------------------------------
section "STEP 4/5: Bundle with quick-sharun"

export ICON="$ROOTFS/usr/share/icons/hicolor/scalable/apps/org.openmoh.openmohaa.svg"
export DESKTOP="$ROOTFS/usr/share/applications/org.openmoh.openmohaa.desktop"
export OUTPATH="$DISTDIR"
export OUTNAME="${APP_NAME}-${ARCH}.AppImage"
export APPDIR

[ -f "$ICON" ]    || { err "Icon not found"; exit 1; }
[ -f "$DESKTOP" ] || { err "Desktop not found"; exit 1; }

# Find all binaries and shared libraries to bundle
# IMPORTANT: OpenMoHAA's pre-built binary has NEEDED entries for libSDL2-2.0.so.0,
# libopenal.so.1, libcurl.so.4 but NO RPATH. These libs are shipped in the same
# directory as the binary in the upstream zip. We MUST pass them to quick-sharun
# explicitly so they get bundled (otherwise quick-sharun reports "missing libraries").
BINARIES_TO_BUNDLE=$(find "$ROOTFS/usr/lib/openmohaa" \
    \( -type f -executable -o -name "*.so" -o -name "*.so.*" \) | sort)

log "Binaries/libraries to bundle:"
echo "$BINARIES_TO_BUNDLE" | sed 's/^/  /'

# Also make sure the .so files from the zip are executable (quick-sharun needs this
# to run ldd on them; without +x, ldd fails with "warning: you do not have execution permission")
chmod +x "$ROOTFS/usr/lib/openmohaa"/*.so* 2>/dev/null || true

log "Running quick-sharun (deploys libc, ld-linux, dlopened libs, etc.)..."
# shellcheck disable=SC2086
quick-sharun $BINARIES_TO_BUNDLE

# --- Copy game modules to bin/ (OpenMoHAA loads them via dlopen from bin/) ---
# quick-sharun puts .so files in lib/ but OpenMoHAA's Sys_LoadDll looks for
# game.so and cgame.so in Sys_BinaryPath() which is bin/. We must copy them.
log "Copying game modules to bin/ (OpenMoHAA dlopens them from there)..."
for _mod in cgame.so game.so; do
    _src=$(find "$APPDIR/lib" -name "$_mod" -type f 2>/dev/null | head -1)
    [ -z "$_src" ] && _src="$ROOTFS/usr/lib/openmohaa/$_mod"
    if [ -n "$_src" ] && [ -f "$_src" ]; then
        cp -f "$_src" "$APPDIR/bin/$_mod"
        log "  Copied: $_mod -> bin/"
    else
        err "  WARNING: $_mod not found!"
    fi
done

# --- Add portable asset detection hooks ---

log "Removing self-updater.hook (causes loops when HOST_XDG_* is unset)..."
rm -f "$APPDIR/bin/self-updater.hook"

log "Installing openmohaa-portable-paths.hook..."
cat > "$APPDIR/bin/openmohaa-portable-paths.hook" <<'HOOK'
#!/bin/sh
# Hook: detect game assets next to the .AppImage file
if [ -n "${OPENMOHAA_BASEPATH:-}" ]; then
    APP_DIR="$OPENMOHAA_BASEPATH"
elif [ -n "${APPIMAGE:-}" ]; then
    APP_DIR=$(dirname "$APPIMAGE")
elif [ -n "${OWD:-}" ]; then
    APP_DIR="$OWD"
else
    APP_DIR="$(pwd)"
fi
export OPENMOHAA_BASEPATH="$APP_DIR"

# Auto-seed cgame.so and game.so into <APP_DIR>/main/ if missing.
# OpenMoHAA loads game modules from <fs_basepath>/<fs_game>/ where fs_game
# defaults to "main". We also seed to <APP_DIR>/ directly because some
# versions of OpenMoHAA look there too.
if [ -n "${APPDIR:-}" ] && [ -d "${APPDIR}/bin" ]; then
    MAIN_DIR="${APP_DIR}/main"
    mkdir -p "$MAIN_DIR" 2>/dev/null || true
    for _mod in cgame.so game.so; do
        _bundled="${APPDIR}/bin/${_mod}"
        # Seed to main/ (standard ioquake3 location)
        _target_main="${MAIN_DIR}/${_mod}"
        if [ -f "$_bundled" ] && [ ! -f "$_target_main" ]; then
            cp -f "$_bundled" "$_target_main" 2>/dev/null || true
        fi
        # Seed to APP_DIR/ directly (OpenMoHAA v0.82+ also looks here)
        _target_root="${APP_DIR}/${_mod}"
        if [ -f "$_bundled" ] && [ ! -f "$_target_root" ]; then
            cp -f "$_bundled" "$_target_root" 2>/dev/null || true
        fi
    done
    unset _mod _bundled _target_main _target_root MAIN_DIR
fi
HOOK
chmod +x "$APPDIR/bin/openmohaa-portable-paths.hook"

log "Patching AppRun.sh (NOT AppRun - it's the sharun binary!)..."
cat > "$APPDIR/AppRun.sh" <<'APPRUN'
#!/bin/sh
if [ "$APPRUN_DEBUG" = 1 ]; then set -x; fi
set -e

MAIN_BIN=openmohaa
ARG0="${ARGV0:-$0}"
unset ARGV0

export PATH=$APPDIR/bin:$PATH
export ARG0 APPDIR PATH

: "${HOST_XDG_CONFIG_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}}"
: "${HOST_XDG_DATA_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}}"
export HOST_XDG_CONFIG_HOME HOST_XDG_DATA_HOME

if [ "$1" = '--appimage-add-env' ]; then
        shift
        for v do echo "$v" >> "$APPIMAGE".env; done
        exit 0
fi

if [ -f "$APPDIR"/AppRun.lib ]; then
        . "$APPDIR"/AppRun.lib
        for hook in $APPDIR/bin/*.hook; do
            [ -e "$hook" ] || continue
            . "$hook"
        done
fi

if [ -f "$APPDIR"/bin/"${ARG0##*/}" ]; then
        TO_LAUNCH=$APPDIR/bin/${ARG0##*/}
elif [ -f "$APPDIR"/bin/"$1" ]; then
        TO_LAUNCH=$APPDIR/bin/$1
        shift
else
        TO_LAUNCH=$APPDIR/bin/$MAIN_BIN
fi

set -- "$TO_LAUNCH" "$@"

# Inject +set fs_basepath so OpenMoHAA finds assets next to the AppImage
if [ -n "${OPENMOHAA_BASEPATH:-}" ]; then
        _has_bp=0; _prev=""
        for _a in "$@"; do
                case "$_prev" in fs_basepath) _has_bp=1 ;; esac
                _prev="$_a"
        done
        if [ $_has_bp -eq 0 ]; then
                _first="$1"; shift
                set -- "$_first" +set fs_basepath "$OPENMOHAA_BASEPATH" "$@"
                if [ "${OPENMOHAA_PORTABLE:-0}" = "1" ]; then
                        _first="$1"; shift
                        set -- "$_first" +set fs_homepath "$OPENMOHAA_BASEPATH" "$@"
                fi
                unset _first
        fi
        unset _has_bp _prev _a
fi

if [ "$APPIMAGE_DEBUG" = 1 ]; then
        cat /etc/os-release >"$PWD"/"${APPIMAGE##*/}"-debug.log || :
        export LD_DEBUG=libs VK_LOADER_DEBUG=all LIBGL_DEBUG=verbose EGL_LOG_LEVEL=debug LC_ALL=C SHARUN_PRINTENV=1
        "$@" 2>>"$PWD"/"${APPIMAGE##*/}"-debug.log || :
        >&2 echo "Debug log at: '$PWD/${APPIMAGE##*/}-debug.log'"
else
        exec "$@"
fi
APPRUN
chmod +x "$APPDIR/AppRun.sh"

log "Verifying AppRun is still the sharun binary (not overwritten)..."
if file "$APPDIR/AppRun" | grep -q "ELF"; then
    log "  OK: AppRun is sharun ELF"
else
    err "  FAIL: AppRun was overwritten!"
    exit 1
fi

# ---------------------------------------------------------------------------
# STEP 5: Generate AppImage
# ---------------------------------------------------------------------------
section "STEP 5/5: Generate AppImage"

log "Turning AppDir into AppImage..."
quick-sharun --make-appimage

APPIMAGE="${DISTDIR}/${OUTNAME}"
[ ! -f "$APPIMAGE" ] && { err "AppImage not created"; exit 1; }

log "AppImage: $(ls -lh "$APPIMAGE" | awk '{print $5, $9}')"

# Verify - check the AppDir directly (extracting the AppImage fails in CI containers
# because FUSE is not available in Docker. The AppDir has the same content).
log "Verifying bundling (from AppDir)..."

if [ -f "$APPDIR/lib/ld-linux-${ARCH}.so.2" ]; then
    log "  OK: ld-linux bundled"
else
    # ld-linux might have a different name on some systems, check alternatives
    if ls "$APPDIR/lib"/ld-linux-*"$ARCH"* 2>/dev/null | head -1 | grep -q .; then
        log "  OK: ld-linux bundled (alternative name: $(ls "$APPDIR/lib"/ld-linux-*"$ARCH"* 2>/dev/null | head -1 | xargs basename))"
    elif ls "$APPDIR/lib"/ld-musl-*"$ARCH"* 2>/dev/null | head -1 | grep -q .; then
        log "  OK: ld-musl bundled (musl libc)"
    else
        err "  FAIL: ld-linux missing"
    fi
fi

[ -f "$APPDIR/lib/libc.so.6" ] && log "  OK: libc bundled" || err "  FAIL: libc missing"
[ -f "$APPDIR/bin/openmohaa-portable-paths.hook" ] && log "  OK: portable hook"

# CRITICAL: verify game modules are in bin/ (OpenMoHAA dlopens them from there)
for _mod in cgame.so game.so; do
    if [ -f "$APPDIR/bin/$_mod" ]; then
        log "  OK: bin/$_mod present (OpenMoHAA will find it)"
    else
        err "  FAIL: bin/$_mod missing - game will crash with 'Couldn't load game'!"
        exit 1
    fi
done

# Verify critical libs from the upstream zip are bundled
for _lib in libSDL2-2.0.so.0 libopenal.so.1 libcurl.so.4; do
    if find "$APPDIR/lib" -name "$_lib*" 2>/dev/null | head -1 | grep -q .; then
        log "  OK: $_lib bundled"
    else
        err "  FAIL: $_lib missing"
    fi
done

LIB_COUNT=$(find "$APPDIR/lib" -maxdepth 1 -type f 2>/dev/null | wc -l)
log "  Total bundled libraries: $LIB_COUNT"

log "Generating checksums..."
( cd "$DISTDIR" && sha256sum "$OUTNAME" > "${OUTNAME}.sha256" )

# Generate/fix appinfo file - make-stable-appimage-release@v1 requires this file
# with the correct version. uruntime generates it from the .desktop file, but
# sometimes the version comes out as UNKNOWN. We overwrite it to be sure.
log "Generating appinfo file..."
cat > "$DISTDIR/appinfo" <<APPINFO
X-AppImage-Name=OpenMoHAA
X-AppImage-Version=${OPENMOHAA_VERSION}
X-AppImage-Arch=${ARCH}
APPINFO
log "appinfo content:"
cat "$DISTDIR/appinfo"

# Verify .zsync file was generated (enables delta updates via UPINFO)
if ls "$DISTDIR"/*.zsync 2>/dev/null | head -1 | grep -q .; then
    log "Zsync file generated: $(ls "$DISTDIR"/*.zsync 2>/dev/null | head -1 | xargs basename)"
else
    warn "No .zsync file found - auto-update via zsync will not work"
fi

log "Files in dist/:"
ls -lh "$DISTDIR/"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Build Summary"

cat <<EOF
App:           $APP_PRETTY $OPENMOHAA_VERSION
Arch:          $ARCH ($OPENMOHAA_ARCH)
AppImage:      $APPIMAGE
Size:          $(ls -lh "$APPIMAGE" | awk '{print $5}')
Libraries:     $LIB_COUNT
Dynamic linker: bundled
libc:          bundled
Portable hook: installed
SHA256:        $(cut -d' ' -f1 "${APPIMAGE}.sha256")

The AppImage is ready. Usage:
  1. Place .pk3 assets in main/ next to the AppImage
  2. ./openmohaa-${ARCH}.AppImage
  3. Server: ./openmohaa-${ARCH}.AppImage omohaaded +quit
EOF

exit 0
