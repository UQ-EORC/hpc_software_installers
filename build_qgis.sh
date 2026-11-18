#!/usr/bin/env bash
#
# build_qgis.sh - build and install QGIS (with Python support) from source on
# this cluster (RHEL 9 / Lmod / EasyBuild GCCcore-13.3.0 / foss-2024a toolchain).
#
# Usage:
#   ./build_qgis.sh [options] <install_prefix>
#
# Options:
#   -v VERSION   QGIS version to build, e.g. 4.2.3       (default: 4.2.3)
#   -j JOBS      parallel build jobs                     (default: nproc)
#   -w WORKDIR   where sources/build trees go            (default: $TMPDIR or /tmp)
#   -k           keep the work directory after a successful build
#   -n           don't add QGIS_HOME / PATH settings to ~/.bashrc, or a
#                QGIS icon to your desktop and applications menu
#   -h           show this help
#
# After install (and a new shell, or 'source ~/.bashrc'), run:
#   qgis                        # GUI, uses VirtualGL when available
#   qgis_process ...            # Processing from the command line, no display needed
#
set -euo pipefail

QGIS_VERSION="4.2.3"
JOBS="$(nproc)"
WORKBASE="${TMPDIR:-/tmp}"
KEEP=0
UPDATE_BASHRC=1

# Dependency versions built from source (not available as modules)
PROTOBUF_VERSION="21.12"
LIBZIP_VERSION="1.10.1"
SPATIALINDEX_VERSION="2.0.0"
EXIV2_VERSION="0.28.3"
SPATIALITE_VERSION="5.1.0"
QTKEYCHAIN_VERSION="0.14.3"
QCA_VERSION="2.3.9"
QSCINTILLA_VERSION="2.14.1"
PDAL_VERSION="2.8.4"
SIP_VERSION="6.8.6"
PYQT_BUILDER_VERSION="1.16.4"
PYQT6_SIP_VERSION="13.8.0"
PYQT6_VERSION="6.7.1"

# Modules from the GCCcore-13.3.0 / 2024a generation (all mutually compatible).
# gdal pulls in PROJ, GEOS, SQLite, Python 3.12, numpy, HDF5, NetCDF, ...
RUNTIME_MODULES=(
    qt6/6.7.2-gcccore-13.3.0
    gdal/3.10.0-foss-2024a
    gsl/2.8-gcc-13.3.0
    postgresql/16.4-gcccore-13.3.0
    libgeotiff/1.7.3-gcccore-13.3.0
    zstd/1.5.6-gcccore-13.3.0
)
MODULES=(
    "${RUNTIME_MODULES[@]}"
    cmake/3.29.3-gcccore-13.3.0
    ninja/1.12.1-gcccore-13.3.0
    flex/2.6.4-gcccore-13.3.0
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
        v) QGIS_VERSION="$OPTARG" ;;
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

WORKDIR="$(mktemp -d "${WORKBASE%/}/qgis-build-${USER}-XXXXXX")"
DEPS="$PREFIX/deps"
VENV="$DEPS/venv"
SRC="$WORKDIR/src"
mkdir -p "$DEPS/lib" "$DEPS/include" "$DEPS/.built" "$SRC"
echo "Install prefix : $PREFIX"
echo "Work directory : $WORKDIR"
echo "QGIS version   : $QGIS_VERSION"
echo "Jobs           : $JOBS"

cleanup() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "Build failed (exit $rc). Work directory kept for inspection: $WORKDIR" >&2
        echo "Re-running the script skips the dependencies that already built." >&2
    elif [[ $KEEP -eq 0 ]]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

# Make everything installed into $DEPS visible to later builds
export CMAKE_PREFIX_PATH="$DEPS${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CPATH="$DEPS/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="$DEPS/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DEPS/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$VENV/bin:$DEPS/bin:$PATH"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# is_built NAME VERSION -> true if this dependency was already installed for
# this CPU type
is_built()   { [[ -e "$DEPS/.built/$1-$2-$BUILD_ARCH" ]]; }
mark_built() { rm -f "$DEPS/.built/$1-"*; touch "$DEPS/.built/$1-$2-$BUILD_ARCH"; }

# A venv left by a build for another CPU type links to that type's python,
# which crashes here; it is on PATH, so remove it before anything runs python3.
is_built venv "$SIP_VERSION" || rm -rf "$VENV"

# fetch_git DIR URL TAG
fetch_git() {
    rm -rf "$SRC/$1"
    git clone -q --depth 1 --branch "$3" "$2" "$SRC/$1" 2>&1 | grep -v 'detached HEAD' || true
    [[ -d "$SRC/$1" ]] || die "failed to clone $2 ($3)"
}

# fetch_tarball DIR URL -> unpacks URL into $SRC/DIR
fetch_tarball() {
    rm -rf "$SRC/$1" && mkdir -p "$SRC/$1"
    curl -fsSL --retry 3 "$2" | tar -xz -C "$SRC/$1" --strip-components=1 \
        || die "failed to download $2"
}

# cmake_install SRCDIR [cmake args...] -> configure, build and install into $DEPS
cmake_install() {
    local src="$1"; shift
    cmake -S "$src" -B "$src/_build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$DEPS" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_RPATH="$DEPS/lib" \
        "$@"
    cmake --build "$src/_build" -j "$JOBS"
    cmake --install "$src/_build"
}

# ---------------------------------------------------------------------------
# C/C++ dependencies not provided as modules
# ---------------------------------------------------------------------------
if ! is_built protobuf "$PROTOBUF_VERSION"; then
    log "Building protobuf $PROTOBUF_VERSION"
    fetch_git protobuf https://github.com/protocolbuffers/protobuf.git "v$PROTOBUF_VERSION"
    cmake_install "$SRC/protobuf" \
        -Dprotobuf_BUILD_TESTS=OFF \
        -Dprotobuf_BUILD_SHARED_LIBS=ON
    mark_built protobuf "$PROTOBUF_VERSION"
fi

if ! is_built libzip "$LIBZIP_VERSION"; then
    log "Building libzip $LIBZIP_VERSION"
    fetch_git libzip https://github.com/nih-at/libzip.git "v$LIBZIP_VERSION"
    cmake_install "$SRC/libzip" \
        -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF \
        -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF
    mark_built libzip "$LIBZIP_VERSION"
fi

if ! is_built spatialindex "$SPATIALINDEX_VERSION"; then
    log "Building libspatialindex $SPATIALINDEX_VERSION"
    fetch_git spatialindex https://github.com/libspatialindex/libspatialindex.git "$SPATIALINDEX_VERSION"
    cmake_install "$SRC/spatialindex" -DBUILD_TESTING=OFF
    mark_built spatialindex "$SPATIALINDEX_VERSION"
fi

if ! is_built exiv2 "$EXIV2_VERSION"; then
    log "Building exiv2 $EXIV2_VERSION"
    fetch_git exiv2 https://github.com/Exiv2/exiv2.git "v$EXIV2_VERSION"
    cmake_install "$SRC/exiv2" \
        -DEXIV2_ENABLE_INIH=OFF -DEXIV2_ENABLE_BROTLI=OFF \
        -DEXIV2_BUILD_SAMPLES=OFF -DEXIV2_BUILD_EXIV2_COMMAND=OFF \
        -DEXIV2_BUILD_UNIT_TESTS=OFF -DEXIV2_BUILD_DOC=OFF
    mark_built exiv2 "$EXIV2_VERSION"
fi

if ! is_built spatialite "$SPATIALITE_VERSION"; then
    log "Building libspatialite $SPATIALITE_VERSION"
    fetch_tarball spatialite \
        "https://www.gaia-gis.it/gaia-sins/libspatialite-sources/libspatialite-$SPATIALITE_VERSION.tar.gz"
    (
        cd "$SRC/spatialite"
        ./configure --prefix="$DEPS" --disable-static --disable-examples \
            --disable-freexl --disable-rttopo --disable-minizip
        make -j "$JOBS"
        make install
    )
    mark_built spatialite "$SPATIALITE_VERSION"
fi

if ! is_built qtkeychain "$QTKEYCHAIN_VERSION"; then
    log "Building QtKeychain $QTKEYCHAIN_VERSION"
    fetch_git qtkeychain https://github.com/frankosterfeld/qtkeychain.git "$QTKEYCHAIN_VERSION"
    cmake_install "$SRC/qtkeychain" -DBUILD_WITH_QT6=ON -DBUILD_TRANSLATIONS=OFF -DBUILD_TESTING=OFF \
        -DLIBSECRET_SUPPORT=OFF
    mark_built qtkeychain "$QTKEYCHAIN_VERSION"
fi

if ! is_built qca "$QCA_VERSION"; then
    log "Building QCA $QCA_VERSION"
    fetch_git qca https://invent.kde.org/libraries/qca.git "v$QCA_VERSION"
    cmake_install "$SRC/qca" \
        -DBUILD_WITH_QT6=ON -DQT6=ON \
        -DBUILD_TESTS=OFF -DBUILD_TOOLS=OFF \
        -DQCA_INSTALL_IN_QT_PREFIX=OFF \
        -DQCA_PLUGINS_INSTALL_DIR="$DEPS/lib/qt6/plugins" \
        -DQCA_FEATURE_INSTALL_DIR="$DEPS/share/qca/mkspecs/features"
    mark_built qca "$QCA_VERSION"
fi

if ! is_built pdal "$PDAL_VERSION"; then
    log "Building PDAL $PDAL_VERSION"
    fetch_git pdal https://github.com/PDAL/PDAL.git "$PDAL_VERSION"
    cmake_install "$SRC/pdal" -DWITH_TESTS=OFF -DBUILD_PGPOINTCLOUD_TESTS=OFF -DWITH_BACKTRACE=OFF
    mark_built pdal "$PDAL_VERSION"
fi

# ---------------------------------------------------------------------------
# Python: venv with sip + PyQt6 + QScintilla built against the Qt6 module
# ---------------------------------------------------------------------------
PY_SITE="$VENV/lib/python$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')/site-packages"

if ! is_built venv "$SIP_VERSION"; then
    log "Creating Python venv"
    rm -rf "$VENV"
    # --system-site-packages: reuse numpy and GDAL's Python bindings from the modules
    python3 -m venv --system-site-packages "$VENV"
    "$VENV/bin/pip" install -q --upgrade pip
    "$VENV/bin/pip" install -q \
        "sip==$SIP_VERSION" "PyQt-builder==$PYQT_BUILDER_VERSION" "PyQt6-sip==$PYQT6_SIP_VERSION" \
        jinja2 pygments owslib pyyaml requests python-dateutil psycopg2
    mark_built venv "$SIP_VERSION"
fi

if ! is_built pyqt6 "$PYQT6_VERSION"; then
    log "Building PyQt6 $PYQT6_VERSION against the Qt6 module (this takes a while)"
    # Fetch the sdist directly: 'pip download --no-binary' runs PyQt6's build
    # backend just to read metadata, which hangs.
    PYQT6_URL="$(curl -fsSL "https://pypi.org/pypi/PyQt6/$PYQT6_VERSION/json" | python3 -c \
        'import json,sys; print(next(u["url"] for u in json.load(sys.stdin)["urls"] if u["packagetype"]=="sdist"))')" \
        || die "could not find the PyQt6 $PYQT6_VERSION source on PyPI"
    fetch_tarball pyqt6 "$PYQT6_URL"
    (
        cd "$SRC/pyqt6"
        "$VENV/bin/sip-install" --confirm-license --qmake "$(command -v qmake)" \
            --no-designer-plugin --no-qml-plugin \
            --jobs "$JOBS" --build-dir "$SRC/pyqt6/_build" --target-dir "$PY_SITE"
    )
    mark_built pyqt6 "$PYQT6_VERSION"
fi

if ! is_built qscintilla "$QSCINTILLA_VERSION"; then
    log "Building QScintilla $QSCINTILLA_VERSION (C++ library + Python bindings)"
    fetch_tarball qscintilla \
        "https://www.riverbankcomputing.com/static/Downloads/QScintilla/$QSCINTILLA_VERSION/QScintilla_src-$QSCINTILLA_VERSION.tar.gz"
    (
        cd "$SRC/qscintilla/src"
        qmake qscintilla.pro
        make -j "$JOBS"
        mkdir -p "$DEPS/include/Qsci" "$DEPS/share/qscintilla"
        cp Qsci/*.h "$DEPS/include/Qsci/"
        cp -P libqscintilla2_qt6.so* "$DEPS/lib/"
        cp -r features "$DEPS/share/qscintilla/"

        cd ../Python
        cp pyproject-qt6.toml pyproject.toml
        "$VENV/bin/sip-install" --qmake "$(command -v qmake)" --jobs "$JOBS" \
            --qsci-features-dir "$DEPS/share/qscintilla/features" \
            --qsci-include-dir "$DEPS/include" \
            --qsci-library-dir "$DEPS/lib" \
            --build-dir "$SRC/qscintilla/Python/_build" --target-dir "$PY_SITE"
    )
    mark_built qscintilla "$QSCINTILLA_VERSION"
fi

# ---------------------------------------------------------------------------
# QGIS
# ---------------------------------------------------------------------------
log "Cloning QGIS $QGIS_VERSION"
fetch_git QGIS https://github.com/qgis/QGIS.git "final-${QGIS_VERSION//./_}"

log "Configuring QGIS"
# The PROJ module's CMake config points at its static libproj.a, which doesn't
# link into a shared library; skipping it makes QGIS find libproj.so instead.
# SQLite is pinned because the NSS module (pulled in by Qt6) ships its own,
# incomplete libsqlite3.so that would otherwise be found first.
cmake -S "$SRC/QGIS" -B "$WORKDIR/build" -G Ninja \
    -DCMAKE_DISABLE_FIND_PACKAGE_PROJ=ON \
    -DSQLITE3_LIBRARY="$EBROOTSQLITE/lib/libsqlite3.so" \
    -DSQLITE3_INCLUDE_DIR="$EBROOTSQLITE/include" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_RPATH="$PREFIX/lib;$PREFIX/lib64;$DEPS/lib" \
    -DBUILD_WITH_QT6=ON \
    -DWITH_PYTHON=ON -DWITH_BINDINGS=ON \
    -DPython_EXECUTABLE="$VENV/bin/python" \
    -DWITH_3D=ON \
    -DWITH_PDAL=ON \
    -DWITH_POSTGRESQL=ON \
    -DWITH_DRACO=OFF \
    -DWITH_QTWEBENGINE=OFF \
    -DWITH_SERVER=OFF \
    -DWITH_QSPATIALITE=OFF \
    -DWITH_QSCIAPI=OFF \
    -DENABLE_TESTS=OFF \
    -DUSE_CCACHE=OFF \
    -DUSE_OPENCL=OFF \
    -DQSCINTILLA_LIBRARY="$DEPS/lib/libqscintilla2_qt6.so" \
    -DQSCINTILLA_INCLUDE_DIR="$DEPS/include"

log "Building QGIS (this takes a long while)"
cmake --build "$WORKDIR/build" -j "$JOBS"

log "Installing to $PREFIX"
cmake --install "$WORKDIR/build"

# ---------------------------------------------------------------------------
# Launchers: 'qgis' (GUI) and 'qgis_process' (command line) in $PREFIX/wrappers,
# which load the runtime modules and set up the environment first. They live
# outside $PREFIX/bin so they don't clash with the real binaries.
# ---------------------------------------------------------------------------
mkdir -p "$PREFIX/wrappers"
QGIS_LIB_PATH="$PREFIX/lib:$PREFIX/lib64:$DEPS/lib"

write_env_header() {
    cat <<EOF
#!/usr/bin/env bash
# QGIS launcher generated by build_qgis.sh ($QGIS_VERSION)
QGIS_BIN_DIR="$PREFIX/bin"
QGIS_MODULES="${RUNTIME_MODULES[*]}"
BUILD_ARCH="$BUILD_ARCH"
QGIS_LIBPATH="$QGIS_LIB_PATH"
QGIS_PYSITE="$PY_SITE"
QGIS_QT_PLUGINS="$DEPS/lib/qt6/plugins"
EOF
    cat <<'EOF'

die() { echo "$(basename "$0"): $*" >&2; exit 1; }

if ! type module &>/dev/null; then
    source /etc/profile.d/modules.sh 2>/dev/null || die "Lmod 'module' command not available"
fi
# shellcheck disable=SC2086
module load $QGIS_MODULES &>/dev/null || die "failed to load modules: $QGIS_MODULES"
cpu_arch() { grep -oE '/sw/auto/[^/]+/[^/:]+/modules' <<<"$MODULEPATH" | head -1 | cut -d/ -f5 | cut -d_ -f1; }
[[ "$(cpu_arch)" == "$BUILD_ARCH" ]] || die "built for ${BUILD_ARCH} nodes, but this node is $(cpu_arch). Run it on a ${BUILD_ARCH} node or rebuild here."
export LD_LIBRARY_PATH="$QGIS_LIBPATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PYTHONPATH="$QGIS_PYSITE${PYTHONPATH:+:$PYTHONPATH}"
export QT_PLUGIN_PATH="$QGIS_QT_PLUGINS${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
EOF
}

{
    write_env_header
    cat <<'EOF'

[[ -n "${DISPLAY:-}" ]] || die "no DISPLAY - start a desktop session (e.g. Open OnDemand), or use qgis_process for command-line processing"

# Use VirtualGL for GPU rendering unless the session already preloads it.
if [[ "${LD_PRELOAD:-}" != *vglfaker* ]]; then
    command -v vglrun &>/dev/null || module load virtualgl &>/dev/null || true
    command -v vglrun &>/dev/null && exec vglrun "$QGIS_BIN_DIR/qgis" "$@"
fi
exec "$QGIS_BIN_DIR/qgis" "$@"
EOF
} > "$PREFIX/wrappers/qgis"

{
    write_env_header
    cat <<'EOF'

[[ -n "${DISPLAY:-}" ]] || export QT_QPA_PLATFORM=offscreen
exec "$QGIS_BIN_DIR/qgis_process" "$@"
EOF
} > "$PREFIX/wrappers/qgis_process"
chmod +x "$PREFIX/wrappers/qgis" "$PREFIX/wrappers/qgis_process"

# ---------------------------------------------------------------------------
# Environment: QGIS_HOME + PATH
# ---------------------------------------------------------------------------
cat > "$PREFIX/qgis_env.sh" <<EOF
# Source this file to use QGIS: source $PREFIX/qgis_env.sh
export QGIS_HOME="$PREFIX"
case ":\$PATH:" in
    *":\$QGIS_HOME/wrappers:"*) ;;
    *) export PATH="\$QGIS_HOME/wrappers:\$PATH" ;;
esac
EOF

if [[ $UPDATE_BASHRC -eq 1 ]]; then
    log "Adding QGIS_HOME to ~/.bashrc"
    BASHRC="$HOME/.bashrc"
    touch "$BASHRC"
    # Replace any block from a previous install so re-running doesn't duplicate it
    sed -i '/^# >>> qgis >>>$/,/^# <<< qgis <<<$/d' "$BASHRC"
    cat >> "$BASHRC" <<EOF
# >>> qgis >>>
# Added by build_qgis.sh
[ -f "$PREFIX/qgis_env.sh" ] && source "$PREFIX/qgis_env.sh"
# <<< qgis <<<
EOF
fi

# ---------------------------------------------------------------------------
# Desktop icon and applications-menu entry. Programs started from the desktop
# don't read ~/.bashrc, so they point at the launcher by full path.
# ---------------------------------------------------------------------------
DESKTOP_FILE="$PREFIX/share/applications/qgis.desktop"
mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=QGIS
GenericName=Geographic Information System
Comment=View, edit and analyse geospatial data
Exec="$PREFIX/wrappers/qgis" %F
Icon=$PREFIX/share/icons/hicolor/256x256/apps/qgis.png
Terminal=false
Categories=Science;Geography;Qt;
StartupWMClass=QGIS4
EOF

if [[ $UPDATE_BASHRC -eq 1 ]]; then
    log "Adding QGIS to the desktop and applications menu"
    for dir in "$HOME/.local/share/applications" "$HOME/Desktop"; do
        mkdir -p "$dir"
        install -m 755 "$DESKTOP_FILE" "$dir/qgis.desktop"
        # Desktops other than MATE also want the icon marked as trusted.
        gio set "$dir/qgis.desktop" metadata::trusted true &>/dev/null || true
    done
fi

log "Done"
cat <<EOF
QGIS $QGIS_VERSION installed to: $PREFIX

EOF
if [[ $UPDATE_BASHRC -eq 1 ]]; then
    echo "QGIS was added to your desktop and applications menu."
    echo "QGIS_HOME and PATH were added to ~/.bashrc. Open a new shell, or run:"
else
    echo "To set QGIS_HOME and PATH, run (or add to your ~/.bashrc):"
fi
cat <<EOF
    source $PREFIX/qgis_env.sh

Then run QGIS with:
    qgis                                   # GUI (uses VirtualGL when available)
    qgis_process list                      # command-line Processing, no display needed
EOF
if [[ $UPDATE_BASHRC -eq 0 ]]; then
    cat <<EOF

To add a QGIS icon to your desktop and applications menu, run:
    install -m 755 $DESKTOP_FILE ~/Desktop/
    install -m 755 $DESKTOP_FILE ~/.local/share/applications/
EOF
fi
