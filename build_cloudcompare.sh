#!/usr/bin/env bash
#
# build_cloudcompare.sh - build and install CloudCompare from source on this
# cluster (RHEL 9 / Lmod / EasyBuild GCCcore-12.3.0 toolchain).
#
# Usage:
#   ./build_cloudcompare.sh [options] <install_prefix>
#
# Options:
#   -v VERSION   CloudCompare git tag/branch to build   (default: v2.13.2)
#   -j JOBS      parallel build jobs                     (default: nproc)
#   -w WORKDIR   where sources/build trees go            (default: $TMPDIR or /tmp)
#   -k           keep the work directory after a successful build
#   -n           don't add CLOUDCOMPARE_HOME / PATH settings to ~/.bashrc, or a
#                CloudCompare icon to your desktop and applications menu
#   -h           show this help
#
# After install (and a new shell, or 'source ~/.bashrc'), run:
#   cloudcompare                # GUI, uses VirtualGL when available
#   cloudcompare -SILENT ...    # command-line mode
#
set -euo pipefail

CC_VERSION="v2.13.2"
LASZIP_VERSION="3.4.4"
EIGEN_VERSION="3.4.0"
JOBS="$(nproc)"
WORKBASE="${TMPDIR:-/tmp}"
KEEP=0
UPDATE_BASHRC=1

# Modules from the GCCcore-12.3.0 / 2023a generation (all mutually compatible)
RUNTIME_MODULES=(
    qt5/5.15.10-gcccore-12.3.0
    boost/1.82.0-gcc-12.3.0
    xerces-c++/3.2.4-gcccore-12.3.0
)
MODULES=(
    "${RUNTIME_MODULES[@]}"
    cmake/3.26.3-gcccore-12.3.0
    ninja/1.11.1-gcccore-12.3.0
)

usage() { sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log()   { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Bunya has one module tree per CPU generation (epyc3, epyc4, epyc5, ...), each
# compiled for that CPU. A build only runs on nodes of the generation it was
# built on, so record it for the launcher to check.
cpu_arch() { grep -oE '/sw/auto/[^/]+/[^/:]+/modules' <<<"$MODULEPATH" | head -1 | cut -d/ -f5 | cut -d_ -f1; }

while getopts "v:j:w:knh" opt; do
    case "$opt" in
        v) CC_VERSION="$OPTARG" ;;
        j) JOBS="$OPTARG" ;;
        w) WORKBASE="$OPTARG" ;;
        k) KEEP=1 ;;
        n) UPDATE_BASHRC=0 ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -eq 1 ]] || usage 1

mkdir -p "$1" || die "cannot create install prefix '$1'"
PREFIX="$(cd "$1" && pwd)"
[[ -w "$PREFIX" ]] || die "install prefix '$PREFIX' is not writable"

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
# VirtualGL's LD_PRELOAD fakers spam errors in every child process; not needed to build.
unset LD_PRELOAD

if ! type module &>/dev/null; then
    # shellcheck disable=SC1091
    source /etc/profile.d/modules.sh 2>/dev/null || die "Lmod 'module' command not available"
fi

log "Loading modules"
module purge &>/dev/null || true
for m in "${MODULES[@]}"; do
    module load "$m" || die "failed to load module $m"
done
module list 2>&1
BUILD_ARCH="$(cpu_arch)"
echo "CPU type       : ${BUILD_ARCH:-unknown}"

WORKDIR="$(mktemp -d "${WORKBASE%/}/cloudcompare-build-${USER}-XXXXXX")"
DEPS="$PREFIX/deps"
echo "Install prefix : $PREFIX"
echo "Work directory : $WORKDIR"
echo "Version        : $CC_VERSION"
echo "Jobs           : $JOBS"

cleanup() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "Build failed (exit $rc). Work directory kept for inspection: $WORKDIR" >&2
    elif [[ $KEEP -eq 0 ]]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Dependencies not provided as modules
# ---------------------------------------------------------------------------
log "Fetching Eigen $EIGEN_VERSION (header-only)"
if [[ ! -d "$DEPS/eigen/Eigen" ]]; then
    git clone -q --depth 1 --branch "$EIGEN_VERSION" \
        https://gitlab.com/libeigen/eigen.git "$WORKDIR/eigen"
    mkdir -p "$DEPS/eigen"
    cp -r "$WORKDIR/eigen/Eigen" "$WORKDIR/eigen/unsupported" "$DEPS/eigen/"
fi

log "Building LASzip $LASZIP_VERSION"
if [[ ! -e "$DEPS/laszip/include/laszip/laszip_api.h" ]]; then
    git clone -q --depth 1 --branch "$LASZIP_VERSION" \
        https://github.com/LASzip/LASzip.git "$WORKDIR/laszip"
    cmake -S "$WORKDIR/laszip" -B "$WORKDIR/laszip/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$DEPS/laszip" \
        -DCMAKE_INSTALL_LIBDIR=lib
    cmake --build "$WORKDIR/laszip/build" -j "$JOBS"
    cmake --install "$WORKDIR/laszip/build"
fi

# ---------------------------------------------------------------------------
# CloudCompare
# ---------------------------------------------------------------------------
log "Cloning CloudCompare $CC_VERSION"
SRC="$WORKDIR/CloudCompare"
git clone -q --depth 1 --branch "$CC_VERSION" \
    https://github.com/CloudCompare/CloudCompare.git "$SRC"

# Plugins to build: "<cmake option suffix> <plugin source dir>".
PLUGINS=(
    "GL_QEDL                          plugins/core/GL/qEDL"
    "GL_QSSAO                         plugins/core/GL/qSSAO"
    "IO_QCORE                         plugins/core/IO/qCoreIO"
    "IO_QADDITIONAL                   plugins/core/IO/qAdditionalIO"
    "IO_QCSV_MATRIX                   plugins/core/IO/qCSVMatrixIO"
    "IO_QE57                          plugins/core/IO/qE57IO"
    "IO_QLAS                          plugins/core/IO/qLASIO"
    "IO_QPHOTOSCAN                    plugins/core/IO/qPhotoscanIO"
    "STANDARD_QANIMATION              plugins/core/Standard/qAnimation"
    "STANDARD_QBROOM                  plugins/core/Standard/qBroom"
    "STANDARD_QCANUPO                 plugins/core/Standard/qCanupo"
    "STANDARD_QCLOUDLAYERS            plugins/core/Standard/qCloudLayers"
    "STANDARD_QCOLORIMETRIC_SEGMENTER plugins/core/Standard/qColorimetricSegmenter"
    "STANDARD_QCOMPASS                plugins/core/Standard/qCompass"
    "STANDARD_QCSF                    plugins/core/Standard/qCSF"
    "STANDARD_QFACETS                 plugins/core/Standard/qFacets"
    "STANDARD_QHOUGH_NORMALS          plugins/core/Standard/qHoughNormals"
    "STANDARD_QHPR                    plugins/core/Standard/qHPR"
    "STANDARD_QM3C2                   plugins/core/Standard/qM3C2"
    "STANDARD_QMPLANE                 plugins/core/Standard/qMPlane"
    "STANDARD_QPCV                    plugins/core/Standard/qPCV"
    "STANDARD_QPOISSON_RECON          plugins/core/Standard/qPoissonRecon"
    "STANDARD_QRANSAC_SD              plugins/core/Standard/qRANSAC_SD"
    "STANDARD_QSRA                    plugins/core/Standard/qSRA"
    "STANDARD_QTREEISO                plugins/core/Standard/qTreeIso"
)

# Fetch submodules one by one: some plugins live on third-party git servers
# that are sometimes down. Core submodules must succeed; if a plugin's
# submodule can't be fetched, that plugin is skipped instead of failing.
log "Fetching submodules"
SKIPPED=()
PLUGIN_FLAGS=()
mapfile -t SUBMODULES < <(git -C "$SRC" config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}')
fetch_submodule() {
    git -C "$SRC" submodule update -q --init --recursive --depth 1 -- "$1" 2>&1 \
        || git -C "$SRC" submodule update -q --init --recursive -- "$1"
}
for sm in "${SUBMODULES[@]}"; do
    [[ "$sm" == plugins/* ]] && continue
    echo "  $sm"
    fetch_submodule "$sm" || die "failed to fetch required submodule $sm"
done
for entry in "${PLUGINS[@]}"; do
    read -r opt dir <<<"$entry"
    ok=1
    for sm in "${SUBMODULES[@]}"; do
        [[ "$sm" == "$dir" || "$sm" == "$dir"/* ]] || continue
        echo "  $sm"
        fetch_submodule "$sm" || ok=0
    done
    if [[ $ok -eq 1 ]]; then
        PLUGIN_FLAGS+=("-DPLUGIN_${opt}=ON")
    else
        printf '\033[1;33mWARNING: could not fetch sources for %s - plugin will be skipped\033[0m\n' "$dir" >&2
        SKIPPED+=("$(basename "$dir")")
        PLUGIN_FLAGS+=("-DPLUGIN_${opt}=OFF")
    fi
done

log "Configuring CloudCompare"
# CloudCompare sets its own install RPATH, so Qt etc. come from the modules
# at runtime (see the launcher below).
cmake -S "$SRC" -B "$WORKDIR/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="$DEPS/laszip;${CMAKE_PREFIX_PATH:-}" \
    -DEIGEN_ROOT_DIR="$DEPS/eigen" \
    -DCCCORELIB_USE_TBB=OFF \
    -DCCCORELIB_USE_CGAL=OFF \
    -DOPTION_USE_SHAPE_LIB=ON \
    -DOPTION_USE_DXF_LIB=ON \
    "${PLUGIN_FLAGS[@]}"

log "Building CloudCompare (this takes a while)"
cmake --build "$WORKDIR/build" -j "$JOBS"

log "Installing to $PREFIX"
cmake --install "$WORKDIR/build"
mkdir -p "$PREFIX/share/icons"
cp "$SRC/qCC/images/icon/cc_icon_256.png" "$PREFIX/share/icons/cloudcompare.png"

# ---------------------------------------------------------------------------
# Launcher: 'cloudcompare' command that loads the runtime modules, then starts
# the GUI (through VirtualGL when available) or command-line mode (-SILENT)
# ---------------------------------------------------------------------------
{
    cat <<EOF
#!/usr/bin/env bash
# CloudCompare launcher generated by build_cloudcompare.sh ($CC_VERSION)
#
#   cloudcompare [file ...]          GUI (uses VirtualGL when available)
#   cloudcompare -SILENT ...         command-line mode, no display needed
CC_BIN="$PREFIX/bin/CloudCompare"
CC_MODULES="${RUNTIME_MODULES[*]}"
BUILD_ARCH="$BUILD_ARCH"
CC_LIBPATH="$PREFIX/lib/cloudcompare:$DEPS/laszip/lib"
EOF
    cat <<'EOF'

die() { echo "cloudcompare: $*" >&2; exit 1; }

if ! type module &>/dev/null; then
    source /etc/profile.d/modules.sh 2>/dev/null || die "Lmod 'module' command not available"
fi
# shellcheck disable=SC2086
module load $CC_MODULES &>/dev/null || die "failed to load modules: $CC_MODULES"
cpu_arch() { grep -oE '/sw/auto/[^/]+/[^/:]+/modules' <<<"$MODULEPATH" | head -1 | cut -d/ -f5 | cut -d_ -f1; }
[[ "$(cpu_arch)" == "$BUILD_ARCH" ]] || die "built for ${BUILD_ARCH} nodes, but this node is $(cpu_arch). Run it on a ${BUILD_ARCH} node or rebuild here."
export LD_LIBRARY_PATH="$CC_LIBPATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

silent=0
for arg in "$@"; do
    [[ "${arg^^}" == "-SILENT" ]] && silent=1 && break
done

if [[ $silent -eq 1 ]]; then
    [[ -n "${DISPLAY:-}" ]] || export QT_QPA_PLATFORM=offscreen
    exec "$CC_BIN" "$@"
fi

[[ -n "${DISPLAY:-}" ]] || die "no DISPLAY - start a desktop session (e.g. Open OnDemand), or use -SILENT for command-line mode"

# Use VirtualGL for GPU rendering unless the session already preloads it.
if [[ "${LD_PRELOAD:-}" != *vglfaker* ]]; then
    command -v vglrun &>/dev/null || module load virtualgl &>/dev/null || true
    command -v vglrun &>/dev/null && exec vglrun "$CC_BIN" "$@"
fi
exec "$CC_BIN" "$@"
EOF
} > "$PREFIX/bin/cloudcompare"
chmod +x "$PREFIX/bin/cloudcompare"
rm -f "$PREFIX/bin/run_cloudcompare"

# ---------------------------------------------------------------------------
# Environment: CLOUDCOMPARE_HOME + PATH
# ---------------------------------------------------------------------------
cat > "$PREFIX/cloudcompare_env.sh" <<EOF
# Source this file to use CloudCompare: source $PREFIX/cloudcompare_env.sh
export CLOUDCOMPARE_HOME="$PREFIX"
case ":\$PATH:" in
    *":\$CLOUDCOMPARE_HOME/bin:"*) ;;
    *) export PATH="\$CLOUDCOMPARE_HOME/bin:\$PATH" ;;
esac
EOF

if [[ $UPDATE_BASHRC -eq 1 ]]; then
    log "Adding CLOUDCOMPARE_HOME to ~/.bashrc"
    BASHRC="$HOME/.bashrc"
    touch "$BASHRC"
    # Replace any block from a previous install so re-running doesn't duplicate it
    sed -i '/^# >>> cloudcompare >>>$/,/^# <<< cloudcompare <<<$/d' "$BASHRC"
    cat >> "$BASHRC" <<EOF
# >>> cloudcompare >>>
# Added by build_cloudcompare.sh
[ -f "$PREFIX/cloudcompare_env.sh" ] && source "$PREFIX/cloudcompare_env.sh"
# <<< cloudcompare <<<
EOF
fi

# ---------------------------------------------------------------------------
# Desktop icon and applications-menu entry. Programs started from the desktop
# don't read ~/.bashrc, so they point at the launcher by full path.
# ---------------------------------------------------------------------------
DESKTOP_FILE="$PREFIX/share/applications/cloudcompare.desktop"
mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=CloudCompare
GenericName=Point cloud processing
Comment=View and process 3D point clouds and meshes
Exec="$PREFIX/bin/cloudcompare" %F
Icon=$PREFIX/share/icons/cloudcompare.png
Terminal=false
Categories=Graphics;3DGraphics;Viewer;Qt;
EOF

if [[ $UPDATE_BASHRC -eq 1 ]]; then
    log "Adding CloudCompare to the desktop and applications menu"
    for dir in "$HOME/.local/share/applications" "$HOME/Desktop"; do
        mkdir -p "$dir"
        install -m 755 "$DESKTOP_FILE" "$dir/cloudcompare.desktop"
        # Desktops other than MATE also want the icon marked as trusted.
        gio set "$dir/cloudcompare.desktop" metadata::trusted true &>/dev/null || true
    done
fi

log "Done"
cat <<EOF
CloudCompare $CC_VERSION installed to: $PREFIX

EOF
if [[ $UPDATE_BASHRC -eq 1 ]]; then
    echo "CloudCompare was added to your desktop and applications menu."
    echo "CLOUDCOMPARE_HOME and PATH were added to ~/.bashrc. Open a new shell, or run:"
else
    echo "To set CLOUDCOMPARE_HOME and PATH, run (or add to your ~/.bashrc):"
fi
cat <<EOF
    source $PREFIX/cloudcompare_env.sh

Then run CloudCompare with:
    cloudcompare                           # GUI (uses VirtualGL when available)
    cloudcompare -SILENT -O cloud.las ...  # command-line mode
EOF
if [[ $UPDATE_BASHRC -eq 0 ]]; then
    cat <<EOF

To add a CloudCompare icon to your desktop and applications menu, run:
    install -m 755 $DESKTOP_FILE ~/Desktop/
    install -m 755 $DESKTOP_FILE ~/.local/share/applications/
EOF
fi
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    printf '\n\033[1;33mSkipped plugins (sources unavailable): %s\033[0m\n' "${SKIPPED[*]}"
    echo "Re-run the script later to try building them again."
fi
