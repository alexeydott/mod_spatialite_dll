# Static MSVC Build of mod_spatialite.dll

This directory contains an automated build of `mod_spatialite.dll` for `win32` and `win64` from downloaded sources from `.\src`.

## Requirements

- Visual Studio 2019 Build Tools for example at:
  - `D:\VisualStudio2019\VC\Auxiliary\Build\vcvars32.bat`
  - `D:\VisualStudio2019\VC\Auxiliary\Build\vcvars64.bat`
- `cmake` and `ninja` in `PATH`.
- `python` and `perl` in `PATH`.
- Tcl available for example at `D:\tools\tcl`; the script adds `D:\tools\tcl\bin` and `D:\tools\tcl` to `PATH` before invoking MSVC.

## Quick Build

```powershell
cd /d D:\projects\externals\spatialite
powershell -ExecutionPolicy Bypass -File .\build-static-mod-spatialite.ps1 -Arch all
```

For a single architecture:

```powershell
powershell -ExecutionPolicy Bypass -File .\build-static-mod-spatialite.ps1 -Arch win32
powershell -ExecutionPolicy Bypass -File .\build-static-mod-spatialite.ps1 -Arch win64
```

If the CMake dependencies are already built and you just need to relink/reinstall faster:

```powershell
powershell -ExecutionPolicy Bypass -File .\build-static-mod-spatialite.ps1 -Arch win64 -SkipClean
```

## What the Script Does

The script builds and installs the dependencies into intermediate directories:

- `.\build\install\win32`
- `.\build\install\win64`

Then it publishes the final artifacts:

- `.\bin\win32\mod_spatialite.dll`
- `.\bin\win64\mod_spatialite.dll`
- `.\lib\win32\*.lib`
- `.\lib\win64\*.lib`
- `.\include\*`

All CMake projects are built with `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`, i.e. with `/MT`. Expat is additionally always rebuilt from a clean build directory with `EXPAT_MSVC_STATIC_CRT=ON` and `EXPAT_RELEASE_POSTFIX=MT` so it does not pick up a stale CMake cache with the `MD` postfix. The Gaia/MSVC makefile files are patched to use `/MT` and local staged-dependency paths.

Before patching makefile/nmake files, `.bak` backups are created next to the original files. On a re-run the script first restores the files from `.bak` and then re-applies the patches, so edits do not accumulate.

## Build Order

1. SQLite, `USE_CRT_DLL=0`, `NO_TCL=1`, `/MT`, JSON enabled by default and explicit feature flags: `SQLITE_ENABLE_FTS3`, `SQLITE_ENABLE_FTS4`, `SQLITE_ENABLE_FTS5`, `SQLITE_ENABLE_RTREE`, `SQLITE_ENABLE_GEOPOLY`, `SQLITE_ENABLE_STMTVTAB`, `SQLITE_ENABLE_DBPAGE_VTAB`, `SQLITE_ENABLE_DBSTAT_VTAB`, `SQLITE_ENABLE_BYTECODE_VTAB`, `SQLITE_ENABLE_CARRAY`, `SQLITE_ENABLE_COLUMN_METADATA`, `SQLITE_ENABLE_MATH_FUNCTIONS`, `SQLITE_ENABLE_PERCENTILE`, `SQLITE_ENABLE_OFFSET_SQL_FUNC`, `SQLITE_ENABLE_STMT_SCANSTATUS`, `SQLITE_ENABLE_EXPLAIN_COMMENTS`.
2. libiconv manually via `cl /MT` and `lib`.
3. zlib via CMake.
4. minizip manually via `cl /MT` and `lib`, so that `win32` works as well.
5. expat via CMake, static CRT.
6. GEOS via CMake, static libs.
7. libxml2 via CMake, static libs, zlib, HTTP enabled for WFS.
8. PROJ via CMake, static libs, without CURL/TIFF apps/tests.
9. FreeXL, librttopo and `mod_spatialite.dll` via the Gaia MSVC makefiles.

For the MSVC configuration of `libspatialite` the script additionally enables `ENABLE_MINIZIP`, `GEOS_3100`, `GEOS_3110`, and fixes the runtime function `HasProj6()` so that it does not overwrite a positive result with zero when built with `PROJ_NEW`.

## Verifying the Result

After the build the script saves the `dumpbin /dependents` output:

- `.\build\mod_spatialite-win32-dependents.txt`
- `.\build\mod_spatialite-win64-dependents.txt`

Expected result: no dependencies on `VCRUNTIME*.dll`, `MSVCP*.dll`, `ucrtbase.dll`, `sqlite3.dll`, `geos*.dll`, `proj*.dll`, `libxml2.dll`, `zlib.dll`, etc. Only system Windows DLLs are acceptable.

For the current successful build, both architectures show only:

```text
bcrypt.dll
SHELL32.dll
ole32.dll
KERNEL32.dll
```

This means `mod_spatialite.dll` is monolithic with respect to third-party dependencies, and no CRT is required as an external DLL.

## Runtime Check of SpatiaLite

To verify that the extension loads:

```powershell
@'
.load ./bin/win64/mod_spatialite.dll
select InitSpatialMetaData(1);
select spatialite_version(), geos_version(), proj_version(), freexl_version(), libxml2_version(), rttopo_version();
select HasMinZip(), HasGeos3100(), HasGeos3110(), HasProj6(), HasProj(), HasRtTopo(), HasLibXml2();
select ST_SRID(Transform(ST_GeomFromText('POINT(37 55)', 4326), 3857));
'@ | .\build\install\win64\bin\sqlite3.exe
```

Do the same for `win32`, replacing the paths with `bin\win32` and `build\install\win32`.

In the current build, both architectures return `1|1|1|1|1|1|1` for `HasMinZip`, `HasGeos3100`, `HasGeos3110`, `HasProj6`, `HasProj`, `HasRtTopo`, `HasLibXml2`; the `EPSG:4326 -> EPSG:3857` transformation returns SRID `3857`.
