#!/bin/bash
# =============================================================================
# build.sh - Build OpenMoHAA AppImage using Anylinux-AppImages methodology
# =============================================================================
set -euo pipefail

APP_NAME="openmohaa"
APP_PRETTY="OpenMoHAA"
UPSTREAM_REPO="openmoh/openmohaa"
UPSTREAM_URL="https://github.com/${UPSTREAM_REPO}.git"
ARCH=$(uname -m)
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
BUILD_CLIENT="${BUILD_CLIENT:-ON}"
BUILD_SERVER="${BUILD_SERVER:-ON}"
BUILD_RENDERER_GL1="${BUILD_RENDERER_GL1:-ON}"
BUILD_RENDERER_GL2="${BUILD_RENDERER_GL2:-ON}"
BUILD_GAME_LIBRARIES="${BUILD_GAME_LIBRARIES:-ON}"
BUILD_GAME_QVMS="${BUILD_GAME_QVMS:-ON}"
USE_INTERNAL_LIBS="${USE_INTERNAL_LIBS:-ON}"
USE_OPENAL="${USE_OPENAL:-ON}"
USE_OPENAL_DLOPEN="${USE_OPENAL_DLOPEN:-ON}"
USE_HTTP="${USE_HTTP:-ON}"
USE_CODEC_VORBIS="${USE_CODEC_VORBIS:-ON}"
USE_CODEC_OPUS="${USE_CODEC_OPUS:-ON}"
USE_CODEC_MAD="${USE_CODEC_MAD:-ON}"

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

WORKDIR="${WORKDIR:-$(pwd)}"
BUILDDIR="${WORKDIR}/build_work"
SRC_DIR="${BUILDDIR}/src"
ROOTFS="${BUILDDIR}/rootfs"
APPDIR="${WORKDIR}/AppDir"
DISTDIR="${WORKDIR}/dist"

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n'  "$*" >&2; }
err()  { printf '\033[1;31m[err]\033[0m %s\n'   "$*" >&2; }
section() { printf '\n\033[1;36m========== %s ==========\033[0m\n' "$*"; }

trap 'err "Build failed at line $LINENO (exit code: $?)"' ERR

# ---------------------------------------------------------------------------
# STEP 1: Install build dependencies (Arch Linux)
# ---------------------------------------------------------------------------
section "STEP 1/6: Install build dependencies"

pacman -Syu --noconfirm --needed \
    base-devel cmake ninja git wget curl strace patchelf flex bison \
    sdl2 sdl2_ttf sdl2_image sdl2_mixer openal libvorbis libogg opus flac \
    libmad curl libpulse pipewire-audio pipewire-jack alsa-lib mesa glu \
    vulkan-icd-loader vulkan-headers libglvnd libdrm libgbm wayland \
    wayland-protocols libxkbcommon libdecor xorg-server-xvfb libx11 libxext \
    libxcursor libxi libxfixes libxrandr libxss libxinerama libxrender \
    libxcb libxau libxdmcp 2>&1 | tail -10 || true

if command -v get-debloated-pkgs >/dev/null 2>&1; then
    get-debloated-pkgs --add-mesa --prefer-nano   || warn "debloat mesa failed"
    get-debloated-pkgs --add-common --prefer-nano || warn "debloat common failed"
fi

# ---------------------------------------------------------------------------
# STEP 2: Clone and compile OpenMoHAA
# ---------------------------------------------------------------------------
section "STEP 2/6: Clone and compile OpenMoHAA"

rm -rf "$BUILDDIR" "$APPDIR" "$DISTDIR"
mkdir -p "$SRC_DIR" "$ROOTFS" "$DISTDIR"

if [ -n "${OPENMOHAA_REF:-}" ]; then
    git clone --depth=1 --branch "$OPENMOHAA_REF" "$UPSTREAM_URL" "$SRC_DIR/openmohaa"
else
    git clone --depth=1 "$UPSTREAM_URL" "$SRC_DIR/openmohaa"
fi

cd "$SRC_DIR/openmohaa"
OPENMOHAA_VERSION=$(git describe --tags --always 2>/dev/null || echo "unknown")
OPENMOHAA_COMMIT=$(git rev-parse --short HEAD)
log "OpenMoHAA version: ${OPENMOHAA_VERSION} (commit ${OPENMOHAA_COMMIT})"

echo "${OPENMOHAA_VERSION}" > "${WORKDIR}/LATEST_VERSION"
echo "${OPENMOHAA_COMMIT}" > "${WORKDIR}/LATEST_COMMIT"

cmake -S "$SRC_DIR/openmohaa" -B "$SRC_DIR/openmohaa/.cmake-build" \
    -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" -DCMAKE_INSTALL_PREFIX=/usr \
    -DBUILD_CLIENT="$BUILD_CLIENT" -DBUILD_SERVER="$BUILD_SERVER" \
    -DBUILD_RENDERER_GL1="$BUILD_RENDERER_GL1" -DBUILD_RENDERER_GL2="$BUILD_RENDERER_GL2" \
    -DBUILD_GAME_LIBRARIES="$BUILD_GAME_LIBRARIES" -DBUILD_GAME_QVMS="$BUILD_GAME_QVMS" \
    -DUSE_INTERNAL_LIBS="$USE_INTERNAL_LIBS" -DUSE_OPENAL="$USE_OPENAL" \
    -DUSE_OPENAL_DLOPEN="$USE_OPENAL_DLOPEN" -DUSE_HTTP="$USE_HTTP" \
    -DUSE_CODEC_VORBIS="$USE_CODEC_VORBIS" -DUSE_CODEC_OPUS="$USE_CODEC_OPUS" \
    -DUSE_CODEC_MAD="$USE_CODEC_MAD" -G Ninja

log "Compiling with ${JOBS} parallel jobs (this can take 5-15 minutes)..."
cmake --build "$SRC_DIR/openmohaa/.cmake-build" --parallel "$JOBS"

# ---------------------------------------------------------------------------
# STEP 3: Install into rootfs
# ---------------------------------------------------------------------------
section "STEP 3/6: Install into rootfs"

DESTDIR="$ROOTFS" cmake --install "$SRC_DIR/openmohaa/.cmake-build" || true

# Create launchers if they weren't installed
for variant in base spearhead breakthrough; do
    if [ ! -f "$ROOTFS/usr/lib/openmohaa/launch_openmohaa_${variant}" ]; then
        cat > "$ROOTFS/usr/lib/openmohaa/launch_openmohaa_${variant}" <<EOF
#!/bin/sh
case "${variant}" in
    spearhead) exec /usr/lib/openmohaa/openmohaa +set fs_game ta "\$@" ;;
    breakthrough) exec /usr/lib/openmohaa/openmohaa +set fs_game tt "\$@" ;;
    *) exec /usr/lib/openmohaa/openmohaa "\$@" ;;
esac
EOF
        chmod +x "$ROOTFS/usr/lib/openmohaa/launch_openmohaa_${variant}"
    fi
done

DESKTOP_FILE="$ROOTFS/usr/share/applications/org.openmoh.openmohaa.desktop"
[ -f "$DESKTOP_FILE" ] && sed -i 's|^Exec=.*|Exec=openmohaa|' "$DESKTOP_FILE"

# ---------------------------------------------------------------------------
# STEP 4: Bundle with quick-sharun
# ---------------------------------------------------------------------------
section "STEP 4/6: Bundle with quick-sharun"

if ! command -v quick-sharun >/dev/null 2>&1; then
    wget -q https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/refs/heads/main/useful-tools/quick-sharun.sh \
        -O /usr/local/bin/quick-sharun
    chmod +x /usr/local/bin/quick-sharun
fi

export ICON="$ROOTFS/usr/share/icons/hicolor/symbolic/apps/org.openmoh.openmohaa.svg"
export DESKTOP="$DESKTOP_FILE"
export OUTPATH="$DISTDIR"
export OUTNAME="${APP_NAME}-${ARCH}.AppImage"
export APPDIR

[ -f "$ICON" ]    || { err "Icon not found"; exit 1; }
[ -f "$DESKTOP" ] || { err "Desktop not found"; exit 1; }

BINARIES_TO_BUNDLE=$(find "$ROOTFS/usr/lib/openmohaa" \
    \( -type f -executable -o -name "*.so" \) | sort)

quick-sharun $BINARIES_TO_BUNDLE

# ---------------------------------------------------------------------------
# STEP 5: Add portable asset detection
# ---------------------------------------------------------------------------
section "STEP 5/6: Add portable asset detection"

log "Copying renderers to bin/..."
for _renderer in renderer_opengl1.so renderer_opengl2.so; do
    _src=$(find "$APPDIR/lib" -name "$_renderer" -type f 2>/dev/null | head -1)
    [ -n "$_src" ] && [ ! -f "$APPDIR/bin/$_renderer" ] && cp -f "$_src" "$APPDIR/bin/$_renderer"
done

log "Copying game modules to bin/..."
for _mod in cgame.so game.so; do
    _src=$(find "$APPDIR/lib" -name "$_mod" -type f 2>/dev/null | head -1)
    [ -z "$_src" ] && _src="$ROOTFS/usr/lib/openmohaa/$_mod"
    [ -n "$_src" ] && [ -f "$_src" ] && [ ! -f "$APPDIR/bin/$_mod" ] && cp -f "$_src" "$APPDIR/bin/$_mod"
done

log "Removing self-updater.hook (causes loops when HOST_XDG_* is unset)..."
rm -f "$APPDIR/bin/self-updater.hook"

log "Installing openmohaa-portable-paths.hook..."
cat > "$APPDIR/bin/openmohaa-portable-paths.hook" <<'HOOK'
#!/bin/sh
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

if [ -n "${APPDIR:-}" ] && [ -d "${APPDIR}/bin" ]; then
    MAIN_DIR="${APP_DIR}/main"
    mkdir -p "$MAIN_DIR" 2>/dev/null || true
    for _mod in cgame.so game.so; do
        _bundled="${APPDIR}/bin/${_mod}"
        _target="${MAIN_DIR}/${_mod}"
        if [ -f "$_bundled" ] && [ ! -f "$_target" ]; then
            cp -f "$_bundled" "$_target" 2>/dev/null || true
        fi
    done
    unset _mod _bundled _target MAIN_DIR
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

# ---------------------------------------------------------------------------
# STEP 6: Generate AppImage
# ---------------------------------------------------------------------------
section "STEP 6/6: Generate AppImage"

quick-sharun --make-appimage

APPIMAGE="${DISTDIR}/${OUTNAME}"
[ ! -f "$APPIMAGE" ] && { err "AppImage not created"; exit 1; }

log "AppImage: $(ls -lh "$APPIMAGE" | awk '{print $5, $9}')"

# Verify
EXTRACT_DIR="${BUILDDIR}/squashfs-root"
rm -rf "$EXTRACT_DIR"
( cd "$BUILDDIR" && "$APPIMAGE" --appimage-extract >/dev/null 2>&1 ) || true

[ -f "$EXTRACT_DIR/lib/ld-linux-${ARCH}.so.2" ] && log "OK: ld-linux bundled"
[ -f "$EXTRACT_DIR/lib/libc.so.6" ] && log "OK: libc bundled"
[ -f "$EXTRACT_DIR/bin/renderer_opengl1.so" ] && log "OK: renderer in bin/"
[ -f "$EXTRACT_DIR/bin/openmohaa-portable-paths.hook" ] && log "OK: portable hook"
file "$APPDIR/AppRun" | grep -q "ELF" && log "OK: AppRun is sharun ELF (not overwritten)"

( cd "$DISTDIR" && sha256sum "$OUTNAME" > "${OUTNAME}.sha256" )

section "Build Summary"
cat <<EOF
App: $APP_PRETTY $OPENMOHAA_VERSION ($OPENMOHAA_COMMIT)
Arch: $ARCH
Size: $(ls -lh "$APPIMAGE" | awk '{print $5}')
SHA256: $(cut -d' ' -f1 "${APPIMAGE}.sha256")

Usage:
  1. Place .pk3 assets in main/ next to the AppImage
  2. ./openmohaa-${ARCH}.AppImage
  3. Server: ./openmohaa-${ARCH}.AppImage omohaaded +quit
EOF

exit 0
