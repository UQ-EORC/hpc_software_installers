# HPC software installers

Scripts that build and install research software on UQ's Bunya HPC cluster
(RHEL 9, Lmod, EasyBuild modules). Each script installs one program into a
directory you choose, sets up a launcher that loads the modules it needs, and
adds the program to your `PATH`.

| Script | Installs | How | Typical time |
|---|---|---|---|
| [`build_cloudcompare.sh`](build_cloudcompare.sh) | [CloudCompare](https://www.cloudcompare.org/) 2.13.2 | compiled from source | about 20 min |
| [`build_qgis.sh`](build_qgis.sh) | [QGIS](https://qgis.org/) 4.2.3 with Python | compiled from source | several hours |
| [`build_meshlab.sh`](build_meshlab.sh) | [MeshLab](https://www.meshlab.net/) 2025.07 | compiled from source | about 15 min |
| [`install_segfix.sh`](install_segfix.sh) | [Segfix](https://github.com/UQ-EORC/Segfix) | PyPI or GitHub | a few minutes |
| [`install_sylva.sh`](install_sylva.sh) | [Sylva](https://github.com/UQ-EORC/Sylva) | PyPI or GitHub | a few minutes (longer with `-g`) |

## Quick start

```bash
git clone https://github.com/UQ-EORC/hpc_software_installers.git
cd hpc_software_installers

./install_segfix.sh /scratch/user/$USER/software/segfix
source ~/.bashrc
segfix
```

Every script takes the install directory as its only argument and has `-h` for
help. Re-running a script on the same directory updates the install in place.

## Before you start

- **Compile on a compute node, not a login node.** CloudCompare, MeshLab and QGIS use
  every core they're given for a long time. Submit them as a job (see
  [below](#building-in-a-batch-job)) or run them in an interactive session.
- **GUI programs need a desktop session**, e.g. an Open OnDemand desktop. The
  launchers start the GUI through VirtualGL, so it renders on the GPU.
- **Build on the type of node you'll run on.** Bunya has a separate module
  tree for each CPU generation (epyc3, epyc4, epyc5), each compiled for that
  CPU. A program built on an epyc5 node crashes with `Illegal instruction` on
  older nodes. The desktop (`gpu_viz`) nodes are mostly epyc3, so build there
  with `#SBATCH --constraint=epyc3`. The launchers check this and tell you if
  the node doesn't match.
- **Choose a lasting install directory**, such as
  `/scratch/user/$USER/software/<name>` or a group directory. Don't install to
  `$TMPDIR`: it is deleted when your job ends.

## Your shell setup

By default each script adds a short block to `~/.bashrc`:

```bash
# >>> qgis >>>
# Added by build_qgis.sh
[ -f "/path/to/qgis/qgis_env.sh" ] && source "/path/to/qgis/qgis_env.sh"
# <<< qgis <<<
```

The sourced file sets `<NAME>_HOME` (`CLOUDCOMPARE_HOME`, `MESHLAB_HOME`,
`QGIS_HOME`, `SEGFIX_HOME`, `SYLVA_HOME`) and puts the launchers on your
`PATH`. Re-running a script replaces its block rather than adding another.

The GUI programs (CloudCompare, MeshLab, QGIS, Segfix) also get an icon on
your desktop and in the applications menu: the script copies
`<install_dir>/share/applications/<name>.desktop` to your desktop folder and
`~/.local/share/applications`. On Bunya's desktops the desktop folder is your
home directory (`xdg-user-dir DESKTOP` prints it).

Pass `-n` to leave `~/.bashrc`, the desktop and the menu alone. That is the
right choice for an install shared by a group: each user then adds one line to
their own `~/.bashrc`, and copies the icon if they want it, e.g.

```bash
source /path/to/shared/qgis/qgis_env.sh
install -m 755 /path/to/shared/qgis/share/applications/qgis.desktop "$(xdg-user-dir DESKTOP)"
install -m 755 /path/to/shared/qgis/share/applications/qgis.desktop ~/.local/share/applications/
```

## CloudCompare

```bash
./build_cloudcompare.sh [options] <install_dir>
```

| Option | Meaning | Default |
|---|---|---|
| `-v VERSION` | CloudCompare git tag or branch | `v2.13.2` |
| `-j JOBS` | parallel build jobs | all cores |
| `-w WORKDIR` | where source and build files go | `$TMPDIR` |
| `-k` | keep the build files after a successful build | |
| `-n` | don't edit `~/.bashrc` or add desktop icons | |

Builds against the GCCcore 12.3.0 modules (Qt 5.15, Boost, Xerces), plus Eigen
and LASzip, which it downloads. 25 plugins are included: LAS and E57 file
support, M3C2, CSF, TreeIso, RANSAC shape detection, Poisson reconstruction,
Compass, Facets, Canupo, the EDL/SSAO shaders and more. A plugin whose source
can't be downloaded is skipped with a warning rather than stopping the build.

```bash
cloudcompare                                                     # GUI
cloudcompare -SILENT -O cloud.xyz -C_EXPORT_FMT LAS -SAVE_CLOUDS  # command line, no display needed
```

## MeshLab

```bash
./build_meshlab.sh [options] <install_dir>
```

| Option | Meaning | Default |
|---|---|---|
| `-v VERSION` | MeshLab release | `2025.07` |
| `-d` | double-precision coordinates | |
| `-j JOBS` | parallel build jobs | all cores |
| `-w WORKDIR` | where source and build files go | `$TMPDIR` |
| `-k` | keep the build files after a successful build | |
| `-n` | don't edit `~/.bashrc` or add desktop icons | |

Builds against the GCCcore 12.3.0 modules (Qt 5.15, Boost, TBB,
GMP/MPFR, Xerces). MeshLab downloads its other dependencies (CGAL, Embree, libigl,
lib3mf, libE57Format, ...) during the build, and all of its plugins are
included. If one of those downloads fails, the plugins that need it are left
out and the script lists them at the end.

Use `-d` for georeferenced meshes, e.g. in UTM coordinates: single precision
can't hold such large coordinates exactly, which shows up as jagged, shifted
geometry. This is the same as the "d" builds MeshLab publishes. It costs some
memory, so leave it off otherwise.

The prebuilt MeshLab download for Linux isn't used because it needs a newer
glibc than RHEL 9 has, so several of its plugins don't load.

```bash
meshlab mesh.ply      # GUI
```

MeshLab has no command-line mode any more. For scripted processing, use
[PyMeshLab](https://pymeshlab.readthedocs.io/) (`pip install pymeshlab`),
which runs the same filters from Python.

## QGIS

```bash
./build_qgis.sh [options] <install_dir>
```

Options are the same as for CloudCompare; `-v` takes a QGIS version such as
`4.2.3`.

Builds QGIS 4 (Qt 6) with Python support against the 2024a modules (Qt 6.7,
GDAL 3.10, PROJ, GEOS, Python 3.12, GSL, PostgreSQL). Libraries missing from
the module tree are built into `<install_dir>/deps`: protobuf, libzip,
libspatialindex, exiv2, SpatiaLite, QtKeychain, QCA, PDAL, PyQt6 and
QScintilla. Each is built once, so if the build fails partway, fix the problem
and re-run: it continues from where it stopped.

```bash
qgis                                     # GUI
qgis_process list                        # list Processing algorithms
qgis_process run native:buffer --INPUT=in.gpkg --DISTANCE=10 --OUTPUT=out.gpkg
```

`qgis_process` needs no display, so it works in batch jobs.

Not included: QGIS Server, QtWebEngine (HTML in some widgets) and Draco.
QtKeychain is built without libsecret, which the cluster doesn't have.

## Segfix

```bash
./install_segfix.sh [options] <install_dir>
```

| Option | Meaning |
|---|---|
| `-v VERSION` | install this PyPI release (default: latest) |
| `-g REF` | install from a GitHub branch or tag instead of PyPI |
| `-n` | don't edit `~/.bashrc` or add a desktop icon |

Installs Segfix into its own Python 3.12 environment. With `-g`, the source is
kept in `<install_dir>/src/Segfix` as an editable install, so Segfix's built-in
updater uses `git pull`.

```bash
segfix
```

## Sylva

```bash
./install_sylva.sh [options] <install_dir>
```

Options are the same as for Segfix. With `-g`, the Rust core is compiled from
source; the cluster's Rust modules are too old for it, so a private Rust
toolchain is installed into `<install_dir>/rust`.

```bash
sylva --help                       # command-line tool
source $SYLVA_HOME/activate.sh     # Python environment where 'import sylva' works
```

Reading RIEGL `.rxp` and `.rdbx` files needs RIEGL's RiVLib and RDB SDK, which
can't be redistributed. Set `RIVLIB_PATH` and `RDBLIB_PATH` to where you
extracted them; see the [Sylva install guide](https://uq-eorc.github.io/Sylva/install/).

## Building in a batch job

```bash
#!/bin/bash
#SBATCH --job-name=build_qgis
#SBATCH --partition=general
#SBATCH --constraint=epyc3
#SBATCH --nodes=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=32G
#SBATCH --time=08:00:00
#SBATCH --output=build_qgis-%j.out

/path/to/hpc_software_installers/build_qgis.sh /scratch/user/$USER/software/qgis
```

Save it as e.g. `build_qgis.slurm`, run `sbatch build_qgis.slurm`, and follow
the progress in `build_qgis-<jobid>.out`. For CloudCompare or MeshLab, 2 hours
is plenty.

## Troubleshooting

- **A build failed.** The script prints where it kept the build files. The
  error is usually just above the `Build failed` line in the job output.
- **`failed to load modules`** when starting a program: the modules it was
  built against have been removed from the cluster. Re-run the install script
  to rebuild against the current ones (update the module versions at the top
  of the script if they no longer exist).
- **`built for epyc5 nodes, but this node is epyc3`** (or `Illegal
  instruction` from an older install): the program was compiled on a different
  CPU generation. Run it on a matching node, or rebuild on the node type you
  use. Re-running the build script rebuilds everything for the new CPU type.
- **`no DISPLAY`**: you started a GUI program outside a desktop session. Use an
  Open OnDemand desktop, or the command-line modes shown above.
