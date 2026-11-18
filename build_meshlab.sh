#!/usr/bin/env bash
#
# build_meshlab.sh - build and install MeshLab from source on this cluster
# (RHEL 9 / Lmod / EasyBuild GCCcore-12.3.0 toolchain).
#
# Usage:
#   ./build_meshlab.sh [options] <install_prefix>
#
# Options:
#   -v VERSION   MeshLab release to build, e.g. 2025.07  (default: 2025.07)
#   -d           use double-precision coordinates (for georeferenced meshes)
#   -j JOBS      parallel build jobs                     (default: nproc)
#   -w WORKDIR   where sources/build trees go            (default: $TMPDIR or /tmp)
#   -k           keep the work directory after a successful build
#   -n           don't add MESHLAB_HOME / PATH settings to ~/.bashrc, or a
#                MeshLab icon to your desktop and applications menu
#   -h           show this help
#
# After install (and a new shell, or 'source ~/.bashrc'), run:
#   meshlab [file ...]          # GUI, uses VirtualGL when available
#
set -euo pipefail

ML_VERSION="2025.07"
DOUBLE=0
JOBS="$(nproc)"
WORKBASE="${TMPDIR:-/tmp}"
KEEP=0
UPDATE_BASHRC=1

# Modules from the GCCcore-12.3.0 / 2023a generation (all mutually compatible).
# MeshLab downloads the rest of its dependencies (CGAL, Embree, libigl, ...)
# itself and builds them into its own libraries.
RUNTIME_MODULES=(
    qt5/5.15.10-gcccore-12.3.0
    tbb/2021.11.0-gcccore-12.3.0
    mpfr/4.2.0-gcccore-12.3.0
    xerces-c++/3.2.4-gcccore-12.3.0
    boost/1.82.0-gcc-12.3.0
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

while getopts "v:dj:w:knh" opt; do
    case "$opt" in
        v) ML_VERSION="${OPTARG#MeshLab-}" ;;
        d) DOUBLE=1 ;;
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

WORKDIR="$(mktemp -d "${WORKBASE%/}/meshlab-build-${USER}-XXXXXX")"
echo "Install prefix : $PREFIX"
echo "Work directory : $WORKDIR"
echo "Version        : $ML_VERSION$([[ $DOUBLE -eq 1 ]] && echo ' (double precision)')"
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
# MeshLab
# ---------------------------------------------------------------------------
log "Cloning MeshLab $ML_VERSION"
SRC="$WORKDIR/meshlab"
git clone -q --depth 1 --branch "MeshLab-$ML_VERSION" --recurse-submodules --shallow-submodules \
    https://github.com/cnr-isti-vclab/meshlab.git "$SRC"

log "Configuring MeshLab (downloads CGAL, Embree, libigl and other dependencies)"
# MeshLab sets an install RPATH to its own lib/meshlab, so Qt etc. come from
# the modules at runtime (see the launcher below).
cmake -S "$SRC" -B "$WORKDIR/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DMESHLAB_BUILD_WITH_DOUBLE_SCALAR="$([[ $DOUBLE -eq 1 ]] && echo ON || echo OFF)" \
    | tee "$WORKDIR/configure.log"

# If MeshLab can't download a dependency it leaves out the plugins that need
# it rather than failing. Report those at the end.
SKIPPED_DEPS="$(grep -E '^-- - .* - skipping' "$WORKDIR/configure.log" || true)"

log "Building MeshLab (this takes a while)"
cmake --build "$WORKDIR/build" -j "$JOBS"

log "Installing to $PREFIX"
# Remove the previous install first, so plugins dropped from this version
# don't linger and get loaded.
rm -rf "$PREFIX/lib/meshlab" "$PREFIX/share/meshlab" "$PREFIX/bin/meshlab"
cmake --install "$WORKDIR/build" > "$WORKDIR/install.log"
mv "$PREFIX/bin/meshlab" "$PREFIX/bin/meshlab.bin"

# ---------------------------------------------------------------------------
# Launcher: 'meshlab' command that loads the runtime modules, then starts the
# GUI (through VirtualGL when available)
# ---------------------------------------------------------------------------
{
    cat <<EOF
#!/usr/bin/env bash
# MeshLab launcher generated by build_meshlab.sh ($ML_VERSION$([[ $DOUBLE -eq 1 ]] && echo ', double precision'))
#
#   meshlab [file ...]          GUI (uses VirtualGL when available)
ML_BIN="$PREFIX/bin/meshlab.bin"
ML_MODULES="${RUNTIME_MODULES[*]}"
BUILD_ARCH="$BUILD_ARCH"
ML_LIBPATH="$PREFIX/lib/meshlab"
EOF
    cat <<'EOF'

die() { echo "meshlab: $*" >&2; exit 1; }

if ! type module &>/dev/null; then
    source /etc/profile.d/modules.sh 2>/dev/null || die "Lmod 'module' command not available"
fi
# shellcheck disable=SC2086
module load $ML_MODULES &>/dev/null || die "failed to load modules: $ML_MODULES"
cpu_arch() { grep -oE '/sw/auto/[^/]+/[^/:]+/modules' <<<"$MODULEPATH" | head -1 | cut -d/ -f5 | cut -d_ -f1; }
[[ "$(cpu_arch)" == "$BUILD_ARCH" ]] || die "built for ${BUILD_ARCH} nodes, but this node is $(cpu_arch). Run it on a ${BUILD_ARCH} node or rebuild here."
export LD_LIBRARY_PATH="$ML_LIBPATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

[[ -n "${DISPLAY:-}" ]] || die "no DISPLAY - start a desktop session (e.g. Open OnDemand). For scripted mesh processing use PyMeshLab instead."

# Use VirtualGL for GPU rendering unless the session already preloads it.
if [[ "${LD_PRELOAD:-}" != *vglfaker* ]]; then
    command -v vglrun &>/dev/null || module load virtualgl &>/dev/null || true
    command -v vglrun &>/dev/null && exec vglrun "$ML_BIN" "$@"
fi
exec "$ML_BIN" "$@"
EOF
} > "$PREFIX/bin/meshlab"
chmod +x "$PREFIX/bin/meshlab"

# ---------------------------------------------------------------------------
# Environment: MESHLAB_HOME + PATH
# ---------------------------------------------------------------------------
cat > "$PREFIX/meshlab_env.sh" <<EOF
# Source this file to use MeshLab: source $PREFIX/meshlab_env.sh
export MESHLAB_HOME="$PREFIX"
case ":\$PATH:" in
    *":\$MESHLAB_HOME/bin:"*) ;;
    *) export PATH="\$MESHLAB_HOME/bin:\$PATH" ;;
esac
EOF

if [[ $UPDATE_BASHRC -eq 1 ]]; then
    log "Adding MESHLAB_HOME to ~/.bashrc"
    BASHRC="$HOME/.bashrc"
    touch "$BASHRC"
    # Replace any block from a previous install so re-running doesn't duplicate it
    sed -i '/^# >>> meshlab >>>$/,/^# <<< meshlab <<<$/d' "$BASHRC"
    cat >> "$BASHRC" <<EOF
# >>> meshlab >>>
# Added by build_meshlab.sh
[ -f "$PREFIX/meshlab_env.sh" ] && source "$PREFIX/meshlab_env.sh"
# <<< meshlab <<<
EOF
fi

# ---------------------------------------------------------------------------
# Desktop icon and applications-menu entry. Programs started from the desktop
# don't read ~/.bashrc, so they point at the launcher by full path.
# ---------------------------------------------------------------------------
DESKTOP_FILE="$PREFIX/share/applications/meshlab.desktop"
mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=MeshLab
GenericName=Mesh processing
Comment=View and process meshes
Exec="$PREFIX/bin/meshlab" %F
Icon=$PREFIX/share/icons/hicolor/512x512/apps/meshlab.png
Terminal=false
Categories=Graphics;3DGraphics;Viewer;Qt;
EOF

if [[ $UPDATE_BASHRC -eq 1 ]]; then
    log "Adding MeshLab to the desktop and applications menu"
    # The desktop folder is set per user (on Bunya's desktops it's the home directory).
    DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
    for dir in "$HOME/.local/share/applications" "$DESKTOP_DIR"; do
        mkdir -p "$dir"
        install -m 755 "$DESKTOP_FILE" "$dir/meshlab.desktop"
        # Desktops other than MATE also want the icon marked as trusted.
        gio set "$dir/meshlab.desktop" metadata::trusted true &>/dev/null || true
    done
fi

log "Done"
cat <<EOF
MeshLab $ML_VERSION installed to: $PREFIX
Plugins built: $(find "$PREFIX/lib/meshlab/plugins" -name '*.so' | wc -l)

EOF
if [[ $UPDATE_BASHRC -eq 1 ]]; then
    echo "MeshLab was added to your desktop and applications menu."
    echo "MESHLAB_HOME and PATH were added to ~/.bashrc. Open a new shell, or run:"
else
    echo "To set MESHLAB_HOME and PATH, run (or add to your ~/.bashrc):"
fi
cat <<EOF
    source $PREFIX/meshlab_env.sh

Then run MeshLab with:
    meshlab                     # GUI (uses VirtualGL when available)
EOF
if [[ $UPDATE_BASHRC -eq 0 ]]; then
    cat <<EOF

To add a MeshLab icon to your desktop and applications menu, run:
    install -m 755 $DESKTOP_FILE "$(xdg-user-dir DESKTOP)"
    install -m 755 $DESKTOP_FILE ~/.local/share/applications/
EOF
fi
if [[ -n "$SKIPPED_DEPS" ]]; then
    printf '\n\033[1;33mSome dependencies could not be downloaded; plugins that need them were left out:\033[0m\n%s\n' "$SKIPPED_DEPS"
    echo "Re-run the script later to try building them again."
fi
