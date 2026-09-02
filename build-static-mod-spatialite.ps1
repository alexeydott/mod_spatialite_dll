param(
    [ValidateSet("all", "win32", "win64")]
    [string]$Arch = "all",
    [switch]$SkipClean
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Src = Join-Path $Root "src"
$BuildRoot = Join-Path $Root "build"
$StageRoot = Join-Path $BuildRoot "install"

$VcVars = @{
    win32 = "D:\VisualStudio2019\VC\Auxiliary\Build\vcvars32.bat"
    win64 = "D:\VisualStudio2019\VC\Auxiliary\Build\vcvars64.bat"
}
$TclDir = "D:\tools\tcl"

$ArchList = if ($Arch -eq "all") { @("win32", "win64") } else { @($Arch) }

function Invoke-Vc {
    param(
        [Parameter(Mandatory=$true)][string]$TargetArch,
        [Parameter(Mandatory=$true)][string]$Command,
        [string]$WorkingDirectory = $Root
    )
    $vc = $VcVars[$TargetArch]
    if (!(Test-Path $vc)) {
        throw "MSVC environment file not found: $vc"
    }
    Push-Location $WorkingDirectory
    try {
        $tclPrefix = ""
        if (Test-Path $TclDir) {
            $tclPrefix = "set PATH=$($TclDir)\bin;$($TclDir);%PATH%`r`n"
        }
        $batchFile = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $batchFile -Value "$tclPrefix`"$vc`"`r`n$Command" -Encoding ASCII
        cmd.exe /d /c "$batchFile"
        Remove-Item $batchFile -Force -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed for ${TargetArch}: $Command"
        }
    }
    finally {
        Pop-Location
    }
}

function Ensure-Dir([string]$Path) {
    if (!(Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Install-CMakeProject {
    param(
        [Parameter(Mandatory=$true)][string]$TargetArch,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$SourceDir,
        [Parameter(Mandatory=$true)][string[]]$Options
    )
    $buildDir = Join-Path $BuildRoot "$Name-$TargetArch"
    $prefix = Join-Path $StageRoot $TargetArch
    Ensure-Dir $buildDir
    Ensure-Dir $prefix

    $optString = ($Options -join " ")
    $configure = "cmake -S `"$SourceDir`" -B `"$buildDir`" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=`"$prefix`" -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded $optString"
    Invoke-Vc $TargetArch $configure
    Invoke-Vc $TargetArch "cmake --build `"$buildDir`" --config Release --parallel"
    Invoke-Vc $TargetArch "cmake --install `"$buildDir`" --config Release"
}

function Build-Sqlite {
    param([Parameter(Mandatory=$true)][string]$TargetArch)

    $prefix = Join-Path $StageRoot $TargetArch
    $sqliteDir = Join-Path $Src "sqlite-src-3530400"
    if ((Test-Path (Join-Path $prefix "lib\sqlite3.lib")) -and
        (Test-Path (Join-Path $prefix "bin\sqlite3.exe")) -and
        (Test-Path (Join-Path $prefix "include\sqlite3.h"))) {
        return
    }
    $sqliteFeatureFlags = @(
        "-DSQLITE_ENABLE_FTS3=1",
        "-DSQLITE_ENABLE_FTS4=1",
        "-DSQLITE_ENABLE_FTS5=1",
        "-DSQLITE_ENABLE_RTREE=1",
        "-DSQLITE_ENABLE_GEOPOLY=1",
        "-DSQLITE_ENABLE_STMTVTAB=1",
        "-DSQLITE_ENABLE_DBPAGE_VTAB=1",
        "-DSQLITE_ENABLE_DBSTAT_VTAB=1",
        "-DSQLITE_ENABLE_BYTECODE_VTAB=1",
        "-DSQLITE_ENABLE_CARRAY=1",
        "-DSQLITE_ENABLE_COLUMN_METADATA=1",
        "-DSQLITE_ENABLE_MATH_FUNCTIONS=1",
        "-DSQLITE_ENABLE_PERCENTILE=1",
        "-DSQLITE_ENABLE_OFFSET_SQL_FUNC=1",
        "-DSQLITE_ENABLE_STMT_SCANSTATUS=1",
        "-DSQLITE_ENABLE_EXPLAIN_COMMENTS=1"
    ) -join " "

    Invoke-Vc $TargetArch "nmake /f Makefile.msc clean" $sqliteDir
    Invoke-Vc $TargetArch "nmake /f Makefile.msc USE_CRT_DLL=0 NO_TCL=1 OPTS=`"$sqliteFeatureFlags`" core" $sqliteDir

    Copy-Item (Join-Path $sqliteDir "libsqlite3.lib") (Join-Path $prefix "lib\sqlite3.lib") -Force
    Copy-Item (Join-Path $sqliteDir "sqlite3.exe") (Join-Path $prefix "bin\sqlite3.exe") -Force
    Copy-Item (Join-Path $sqliteDir "sqlite3.h") (Join-Path $prefix "include\sqlite3.h") -Force
    Copy-Item (Join-Path $sqliteDir "sqlite3ext.h") (Join-Path $prefix "include\sqlite3ext.h") -Force
}

function Build-LibIconv {
    param([Parameter(Mandatory=$true)][string]$TargetArch)

    $prefix = Join-Path $StageRoot $TargetArch
    $iconvRoot = Join-Path $Src "libiconv-1.19"
    $outDir = Join-Path $BuildRoot "libiconv-$TargetArch"
    if ((Test-Path (Join-Path $prefix "lib\iconv.lib")) -and
        (Test-Path (Join-Path $prefix "include\iconv.h"))) {
        return
    }
    Ensure-Dir $outDir
    Ensure-Dir (Join-Path $prefix "include")
    Ensure-Dir (Join-Path $prefix "lib")

    $config = @"
#define HAVE_STDDEF_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_SETLOCALE 1
#define HAVE_MBRTOWC 1
#define HAVE_WCRTOMB 1
#define HAVE_VISIBILITY 0
#define WORDS_LITTLEENDIAN 1
#define ICONV_CONST
#define INSTALLPREFIX "$($prefix.Replace('\','/'))"
#define ssize_t SSIZE_T
"@
    Set-Content -Path (Join-Path $outDir "config.h") -Value $config -Encoding ASCII

    $iconvTemplate = Get-Content (Join-Path $iconvRoot "include\iconv.h.build.in") -Raw
    $iconvHeader = $iconvTemplate.
        Replace("@HAVE_VISIBILITY@", "0").
        Replace("@DLL_VARIABLE@", "").
        Replace("@EILSEQ@", "42").
        Replace("@ICONV_CONST@", "").
        Replace("@USE_MBSTATE_T@", "1").
        Replace("@BROKEN_WCHAR_H@", "0")
    Set-Content -Path (Join-Path $prefix "include\iconv.h") -Value $iconvHeader -Encoding ASCII
    $localCharsetTemplate = Get-Content (Join-Path $iconvRoot "libcharset\include\localcharset.h.build.in") -Raw
    $localCharsetHeader = $localCharsetTemplate.Replace("@HAVE_VISIBILITY@", "0")
    Set-Content -Path (Join-Path $outDir "localcharset.h") -Value $localCharsetHeader -Encoding ASCII
    Set-Content -Path (Join-Path $prefix "include\localcharset.h") -Value $localCharsetHeader -Encoding ASCII

    $includeFlags = "/I`"$outDir`" /I`"$iconvRoot\lib`" /I`"$iconvRoot\include`" /I`"$prefix\include`" /I`"$iconvRoot\libcharset\include`" /I`"$iconvRoot\libcharset\lib`""
    $defs = "/DBUILDING_LIBICONV /DBUILDING_LIBCHARSET /DWINDOWS_NATIVE /D_CRT_SECURE_NO_WARNINGS"
    Invoke-Vc $TargetArch "cl /nologo /MT /O2 /W3 $defs $includeFlags /c `"$iconvRoot\lib\iconv.c`" /Fo`"$outDir\iconv.obj`""
    Invoke-Vc $TargetArch "cl /nologo /MT /O2 /W3 $defs $includeFlags /c `"$iconvRoot\lib\compat.c`" /Fo`"$outDir\compat.obj`""
    Invoke-Vc $TargetArch "cl /nologo /MT /O2 /W3 $defs $includeFlags /c `"$iconvRoot\libcharset\lib\localcharset.c`" /Fo`"$outDir\localcharset.obj`""
    Invoke-Vc $TargetArch "lib /nologo /out:`"$prefix\lib\iconv.lib`" `"$outDir\iconv.obj`" `"$outDir\compat.obj`" `"$outDir\localcharset.obj`""
}

function Build-Minizip {
    param([Parameter(Mandatory=$true)][string]$TargetArch)

    $prefix = Join-Path $StageRoot $TargetArch
    $minizipDir = Join-Path $Src "zlib-1.3.2\contrib\minizip"
    $outDir = Join-Path $BuildRoot "minizip-$TargetArch"
    Ensure-Dir $outDir
    Ensure-Dir (Join-Path $prefix "include")
    Ensure-Dir (Join-Path $prefix "include\minizip")
    Ensure-Dir (Join-Path $prefix "lib")

    foreach ($obj in Get-ChildItem -Path $outDir -Filter "*.obj" -ErrorAction SilentlyContinue) {
        Remove-Item $obj.FullName -Force
    }

    foreach ($header in @("crypt.h", "ints.h", "ioapi.h", "iowin32.h", "mztools.h", "unzip.h", "zip.h")) {
        Copy-Item (Join-Path $minizipDir $header) (Join-Path $prefix "include\$header") -Force
        Copy-Item (Join-Path $minizipDir $header) (Join-Path $prefix "include\minizip\$header") -Force
    }

    $includeFlags = "/I`"$prefix\include`" /I`"$minizipDir`""
    $defs = "/D_CRT_SECURE_NO_WARNINGS /D_CRT_NONSTDC_NO_WARNINGS"
    foreach ($source in @("ioapi.c", "iowin32.c", "mztools.c", "unzip.c", "zip.c")) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($source)
        Invoke-Vc $TargetArch "cl /nologo /MT /O2 /W3 $defs $includeFlags /c `"$minizipDir\$source`" /Fo`"$outDir\$base.obj`""
    }
    Invoke-Vc $TargetArch "lib /nologo /out:`"$prefix\lib\libminizip.lib`" `"$outDir\ioapi.obj`" `"$outDir\iowin32.obj`" `"$outDir\mztools.obj`" `"$outDir\unzip.obj`" `"$outDir\zip.obj`""
}

function Normalize-LibraryNames {
    param([Parameter(Mandatory=$true)][string]$TargetArch)
    $prefix = Join-Path $StageRoot $TargetArch
    $lib = Join-Path $prefix "lib"

    $renames = @{
        "zlibstatic.lib" = "zlib.lib"
        "zs.lib" = "zlib.lib"
        "libminizips.lib" = "libminizip.lib"
        "minizips.lib" = "libminizip.lib"
        "libexpatMT.lib" = "libexpat.lib"
        "expat.lib" = "libexpat.lib"
        "LibXml2.lib" = "libxml2.lib"
        "libxml2s.lib" = "libxml2.lib"
        "proj_9_8.lib" = "proj.lib"
    }
    foreach ($srcName in $renames.Keys) {
        $srcPath = Join-Path $lib $srcName
        $dstPath = Join-Path $lib $renames[$srcName]
        if ((Test-Path $srcPath) -and ($srcPath.ToLowerInvariant() -ne $dstPath.ToLowerInvariant())) {
            Copy-Item $srcPath $dstPath -Force
        }
    }
    $minizipInclude = Join-Path $prefix "include\minizip"
    Ensure-Dir $minizipInclude
    foreach ($header in @("crypt.h", "ints.h", "ioapi.h", "mztools.h", "unzip.h", "zip.h")) {
        $srcHeader = Join-Path $prefix "include\$header"
        if (Test-Path $srcHeader) {
            Copy-Item $srcHeader (Join-Path $minizipInclude $header) -Force
        }
    }
}

function Backup-And-PatchGaiaFiles {
    $files = @(
        "src\freexl-2.0.0\nmake.opt",
        "src\freexl-2.0.0\nmake64.opt",
        "src\freexl-2.0.0\makefile.vc",
        "src\freexl-2.0.0\makefile64.vc",
        "src\librttopo-1.1.0\nmake.opt",
        "src\librttopo-1.1.0\nmake64.opt",
        "src\librttopo-1.1.0\makefile.vc",
        "src\librttopo-1.1.0\makefile64.vc",
        "src\readosm-1.1.0a\nmake.opt",
        "src\readosm-1.1.0a\nmake64.opt",
        "src\libspatialite-5.1.0\nmake_mod.opt",
        "src\libspatialite-5.1.0\nmake_mod64.opt",
        "src\libspatialite-5.1.0\makefile_mod.vc",
        "src\libspatialite-5.1.0\makefile_mod64.vc",
        "src\libspatialite-5.1.0\src\headers\spatialite\gaiaconfig-msvc.h",
        "src\libspatialite-5.1.0\src\spatialite\spatialite.c"
    )
    foreach ($rel in $files) {
        $path = Join-Path $Root $rel
        $bak = "$path.bak"
        if (!(Test-Path $bak)) {
            Copy-Item $path $bak -Force
        }
        else {
            Copy-Item $bak $path -Force
        }
    }
}

function Patch-TextFile {
    param([string]$Path, [hashtable]$Replacements)
    $text = Get-Content $Path -Raw
    foreach ($key in $Replacements.Keys) {
        $replacement = $Replacements[$key].Replace('$', '$$')
        $text = [regex]::Replace($text, [regex]::Escape($key), $replacement, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    Set-Content -Path $Path -Value $text -Encoding ASCII
}

function Patch-RegexFile {
    param([string]$Path, [hashtable]$Replacements)
    $text = Get-Content $Path -Raw
    foreach ($pattern in $Replacements.Keys) {
        $replacement = $Replacements[$pattern]
        $text = [regex]::Replace($text, $pattern, $replacement, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    Set-Content -Path $Path -Value $text -Encoding ASCII
}

function Patch-GaiaFiles {
    Backup-And-PatchGaiaFiles

    Patch-TextFile (Join-Path $Src "freexl-2.0.0\nmake.opt") @{
        "INSTDIR=C:\OSGeo4W" = "INSTDIR=$StageRoot\win32"
        "/MD" = "/MT"
        "/DDLL_EXPORT" = "/DDLL_EXPORT /DXML_STATIC"
    }
    Patch-TextFile (Join-Path $Src "freexl-2.0.0\nmake64.opt") @{
        "INSTDIR=C:\OSGeo4W64" = "INSTDIR=$StageRoot\win64"
        "/MD" = "/MT"
        "/DDLL_EXPORT" = "/DDLL_EXPORT /DXML_STATIC"
    }
    Patch-TextFile (Join-Path $Src "librttopo-1.1.0\nmake.opt") @{
        "INSTDIR=C:\OSGeo4W" = "INSTDIR=$StageRoot\win32"
        "/MD" = "/MT"
    }
    Patch-TextFile (Join-Path $Src "librttopo-1.1.0\nmake64.opt") @{
        "INSTDIR=C:\OSGeo4W64" = "INSTDIR=$StageRoot\win64"
        "/MD" = "/MT"
    }
    Patch-TextFile (Join-Path $Src "libspatialite-5.1.0\nmake_mod.opt") @{
        "INSTDIR=C:\OSGeo4W" = "INSTDIR=$StageRoot\win32"
        "/MD" = "/MT"
        "/DLOADABLE_EXTENSION" = "/DLOADABLE_EXTENSION /DXML_STATIC /DLIBXML_STATIC /DPROJ_DLL="
    }
    Patch-TextFile (Join-Path $Src "libspatialite-5.1.0\nmake_mod64.opt") @{
        "INSTDIR=C:\OSGeo4W64" = "INSTDIR=$StageRoot\win64"
        "/MD" = "/MT"
        "/DLOADABLE_EXTENSION" = "/DLOADABLE_EXTENSION /DXML_STATIC /DLIBXML_STATIC /DPROJ_DLL="
    }
    Patch-TextFile (Join-Path $Src "readosm-1.1.0a\nmake.opt") @{
        "INSTDIR=C:\OSGeo4W" = "INSTDIR=$StageRoot\win32"
        "/MD" = "/MT"
        "/DDLL_EXPORT" = "/DDLL_EXPORT /DXML_STATIC"
    }
    Patch-TextFile (Join-Path $Src "readosm-1.1.0a\nmake64.opt") @{
        "INSTDIR=C:\OSGeo4W64" = "INSTDIR=$StageRoot\win64"
        "/MD" = "/MT"
        "/DDLL_EXPORT" = "/DDLL_EXPORT /DXML_STATIC"
    }

    Patch-TextFile (Join-Path $Src "freexl-2.0.0\makefile.vc") @{
        "C:\OSGeo4W\include" = "$StageRoot\win32\include"
        "C:\OSGeo4W\lib\iconv.lib" = "$StageRoot\win32\lib\iconv.lib"
        "C:\OSGeo4W\lib\libexpat.lib" = "$StageRoot\win32\lib\libexpat.lib"
        "C:\OSGeo4W\lib\libminizip.lib" = "$StageRoot\win32\lib\libminizip.lib"
        "C:\OSGeo4w\lib\zlib.lib" = "$StageRoot\win32\lib\zlib.lib"
    }
    Patch-TextFile (Join-Path $Src "freexl-2.0.0\makefile64.vc") @{
        "C:\OSGeo4W64\include" = "$StageRoot\win64\include"
        "C:\OSGeo4W64\lib\iconv.lib" = "$StageRoot\win64\lib\iconv.lib"
        "C:\OSGeo4W64\lib\libexpat.lib" = "$StageRoot\win64\lib\libexpat.lib"
        "C:\OSGeo4W64\lib\libminizip.lib" = "$StageRoot\win64\lib\libminizip.lib"
        "C:\OSGeo4W64\lib\zlib.lib" = "$StageRoot\win64\lib\zlib.lib"
    }
    Patch-TextFile (Join-Path $Src "librttopo-1.1.0\makefile.vc") @{
        "C:\OSGeo4W\include" = "$StageRoot\win32\include"
        "C:\OSGeo4W\lib\geos_c.lib" = "$StageRoot\win32\lib\geos_c.lib $StageRoot\win32\lib\geos.lib"
    }
    Patch-TextFile (Join-Path $Src "librttopo-1.1.0\makefile64.vc") @{
        "C:\OSGeo4W64\include" = "$StageRoot\win64\include"
        "C:\OSGeo4W64\lib\geos_c.lib" = "$StageRoot\win64\lib\geos_c.lib $StageRoot\win64\lib\geos.lib"
    }
    Patch-TextFile (Join-Path $Src "libspatialite-5.1.0\makefile_mod.vc") @{
        "C:\OSGeo4W\include" = "$StageRoot\win32\include -I$StageRoot\win32\include\libxml2"
        "C:\OSGeo4W\lib\proj_i.lib C:\OSGeo4W\lib\geos_c.lib" = "$StageRoot\win32\lib\proj.lib $StageRoot\win32\lib\geos_c.lib $StageRoot\win32\lib\geos.lib"
        "C:\OSGeo4w\lib\freexl_i.lib C:\OSGeo4w\lib\iconv.lib" = "$StageRoot\win32\lib\freexl.lib $StageRoot\win32\lib\iconv.lib"
        "C:\OSGeo4W\lib\sqlite3_i.lib C:\OSGeo4W\lib\zlib.lib" = "$StageRoot\win32\lib\sqlite3.lib $StageRoot\win32\lib\zlib.lib $StageRoot\win32\lib\libexpat.lib $StageRoot\win32\lib\libminizip.lib"
        "C:\OSGeo4W\lib\libxml2.lib C:\OSGeo4W\lib\librttopo.lib" = "$StageRoot\win32\lib\libxml2.lib $StageRoot\win32\lib\librttopo.lib bcrypt.lib ws2_32.lib shell32.lib ole32.lib"
    }
    Patch-TextFile (Join-Path $Src "libspatialite-5.1.0\makefile_mod64.vc") @{
        "C:\OSGeo4W64\include -IC:\OSGeo4W64\include\libxml2" = "$StageRoot\win64\include -I$StageRoot\win64\include\libxml2"
        "C:\OSGeo4W64\lib\proj_i.lib C:\OSGeo4W64\lib\geos_c.lib" = "$StageRoot\win64\lib\proj.lib $StageRoot\win64\lib\geos_c.lib $StageRoot\win64\lib\geos.lib"
        "C:\OSGeo4w64\lib\freexl_i.lib C:\OSGeo4w64\lib\iconv.lib" = "$StageRoot\win64\lib\freexl.lib $StageRoot\win64\lib\iconv.lib"
        "C:\OSGeo4W64\lib\sqlite3_i.lib C:\OSGeo4W64\lib\zlib.lib" = "$StageRoot\win64\lib\sqlite3.lib $StageRoot\win64\lib\zlib.lib $StageRoot\win64\lib\libexpat.lib $StageRoot\win64\lib\libminizip.lib"
        "C:\OSGeo4W64\lib\libxml2.lib C:\OSGeo4W64\lib\librttopo.lib" = "$StageRoot\win64\lib\libxml2.lib $StageRoot\win64\lib\librttopo.lib bcrypt.lib ws2_32.lib shell32.lib ole32.lib"
    }
    Patch-TextFile (Join-Path $Src "libspatialite-5.1.0\src\headers\spatialite\gaiaconfig-msvc.h") @{
        "#define ENABLE_LIBXML2 1" = "#define ENABLE_LIBXML2 1`r`n`r`n/* Should be defined in order to enable MiniZIP support. */`r`n#define ENABLE_MINIZIP 1"
        "#define GEOS_370 1" = "#define GEOS_370 1`r`n`r`n/* Should be defined in order to enable GEOS_3100 support. */`r`n#define GEOS_3100 1`r`n`r`n/* Should be defined in order to enable GEOS_3110 support. */`r`n#define GEOS_3110 1"
        "#define OMIT_GEOCALLBACKS 1" = "/* #undef OMIT_GEOCALLBACKS */"
    }
    Patch-RegexFile (Join-Path $Src "libspatialite-5.1.0\src\spatialite\spatialite.c") @{
        "(?s)(fnct_has_proj6.*?sqlite3_result_int \(context, 1\);)\s*#endif\s*#endif\s*sqlite3_result_int \(context, 0\);" = "`$1`r`n    return;`r`n#endif`r`n#endif`r`n    sqlite3_result_int (context, 0);"
    }
}

function Clear-GaiaBuildProducts {
    param([Parameter(Mandatory=$true)][string]$SourceDir)

    foreach ($pattern in @("*.obj", "*.lib", "*.dll", "*.exp", "*.pdb", "*.ilk", "*.manifest")) {
        Get-ChildItem -Path $SourceDir -Recurse -Filter $pattern -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Build-GaiaNMake {
    param([Parameter(Mandatory=$true)][string]$TargetArch)
    $is64 = $TargetArch -eq "win64"
    $freeMake = if ($is64) { "makefile64.vc" } else { "makefile.vc" }
    $rttMake = if ($is64) { "makefile64.vc" } else { "makefile.vc" }
    $modMake = if ($is64) { "makefile_mod64.vc" } else { "makefile_mod.vc" }

    $freexl = Join-Path $Src "freexl-2.0.0"
    $rttopo = Join-Path $Src "librttopo-1.1.0"
    $spatialite = Join-Path $Src "libspatialite-5.1.0"

    Clear-GaiaBuildProducts $freexl
    Invoke-Vc $TargetArch "nmake /f $freeMake clean" $freexl
    Invoke-Vc $TargetArch "nmake /f $freeMake install" $freexl
    Clear-GaiaBuildProducts $rttopo
    Invoke-Vc $TargetArch "nmake /f $rttMake clean" $rttopo
    Invoke-Vc $TargetArch "nmake /f $rttMake install" $rttopo
    Clear-GaiaBuildProducts $spatialite
    Invoke-Vc $TargetArch "nmake /f $modMake clean" $spatialite
    Invoke-Vc $TargetArch "nmake /f $modMake install" $spatialite
}

function Publish-Outputs {
    param([Parameter(Mandatory=$true)][string]$TargetArch)
    $prefix = Join-Path $StageRoot $TargetArch
    $finalLib = Join-Path $Root "lib\$TargetArch"
    $finalBin = Join-Path $Root "bin\$TargetArch"
    $finalInclude = Join-Path $Root "include"
    Ensure-Dir $finalLib
    Ensure-Dir $finalBin
    Ensure-Dir $finalInclude

    Remove-Item -Force (Join-Path $finalLib "libexpatMD.lib") -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $prefix "lib\*.lib") $finalLib -Force
    Copy-Item (Join-Path $prefix "bin\mod_spatialite.dll") $finalBin -Force
    Copy-Item (Join-Path $prefix "include\*") $finalInclude -Recurse -Force
}

Patch-GaiaFiles

foreach ($target in $ArchList) {
    $prefix = Join-Path $StageRoot $target
    Ensure-Dir (Join-Path $prefix "bin")
    Ensure-Dir (Join-Path $prefix "lib")
    Ensure-Dir (Join-Path $prefix "include")

    if (!$SkipClean) {
        Remove-Item -Recurse -Force (Join-Path $BuildRoot "zlib-$target") -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force (Join-Path $BuildRoot "minizip-$target") -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force (Join-Path $BuildRoot "expat-$target") -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force (Join-Path $BuildRoot "geos-$target") -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force (Join-Path $BuildRoot "libxml2-$target") -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force (Join-Path $BuildRoot "proj-$target") -ErrorAction SilentlyContinue
    }

    Build-Sqlite $target
    Build-LibIconv $target

    Install-CMakeProject $target "zlib" (Join-Path $Src "zlib-1.3.2") @(
        "-DZLIB_BUILD_SHARED=OFF",
        "-DZLIB_BUILD_STATIC=ON",
        "-DZLIB_BUILD_TESTING=OFF"
    )
    Normalize-LibraryNames $target

    Build-Minizip $target
    Normalize-LibraryNames $target

    Remove-Item -Recurse -Force (Join-Path $BuildRoot "expat-$target") -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $prefix "lib\libexpat*.lib") -ErrorAction SilentlyContinue
    Install-CMakeProject $target "expat" (Join-Path $Src "libexpat-R_2_8_1\expat") @(
        "-DBUILD_SHARED_LIBS=OFF",
        "-DEXPAT_BUILD_TOOLS=OFF",
        "-DEXPAT_BUILD_EXAMPLES=OFF",
        "-DEXPAT_BUILD_TESTS=OFF",
        "-DEXPAT_BUILD_DOCS=OFF",
        "-DEXPAT_BUILD_PKGCONFIG=OFF",
        "-DEXPAT_MSVC_STATIC_CRT=ON",
        "-DEXPAT_RELEASE_POSTFIX=MT"
    )
    Normalize-LibraryNames $target

    Install-CMakeProject $target "geos" (Join-Path $Src "geos-3.14.1") @(
        "-DBUILD_SHARED_LIBS=OFF",
        "-DBUILD_TESTING=OFF",
        "-DGEOS_BUILD_DEVELOPER=OFF",
        "-DGEOS_BUILD_TESTS=OFF"
    )
    Normalize-LibraryNames $target

    Install-CMakeProject $target "libxml2" (Join-Path $Src "libxml2-v2.15.3") @(
        "-DBUILD_SHARED_LIBS=OFF",
        "-DLIBXML2_WITH_PROGRAMS=OFF",
        "-DLIBXML2_WITH_TESTS=OFF",
        "-DLIBXML2_WITH_ICONV=OFF",
        "-DLIBXML2_WITH_ZLIB=ON",
        "-DLIBXML2_WITH_HTTP=ON",
        "-DLIBXML2_WITH_MODULES=OFF",
        "-DZLIB_INCLUDE_DIR=`"$prefix\include`"",
        "-DZLIB_LIBRARY=`"$prefix\lib\zlib.lib`""
    )
    Normalize-LibraryNames $target

    Install-CMakeProject $target "proj" (Join-Path $Src "proj-9.8.1") @(
        "-DBUILD_SHARED_LIBS=OFF",
        "-DBUILD_TESTING=OFF",
        "-DBUILD_APPS=OFF",
        "-DENABLE_CURL=OFF",
        "-DENABLE_TIFF=OFF",
        "-DSQLite3_INCLUDE_DIR=`"$prefix\include`"",
        "-DSQLite3_LIBRARY=`"$prefix\lib\sqlite3.lib`""
    )
    Normalize-LibraryNames $target

    Build-GaiaNMake $target
    Publish-Outputs $target

    Invoke-Vc $target "dumpbin /dependents `"$Root\bin\$target\mod_spatialite.dll`" > `"$BuildRoot\mod_spatialite-$target-dependents.txt`""
}

Write-Host "Done. DLLs are in bin\win32 and bin\win64."
