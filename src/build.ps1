<#
.SYNOPSIS
    Windows native (MSVC) build for Mod Relay — shared by CI and local dev.

.DESCRIPTION
    Mirrors src/Makefile target-for-target and command-for-command. This is the
    single source of truth for MSVC builds — both GitHub CI workflows
    (.github/workflows/pr.yml and .github/workflows/release-please.yml) invoke it
    for MSVC builds, and Windows developers use it for local builds.

    Targets PowerShell 5.1 (universal on Windows 10/11). No PS 7-only syntax,
    no external modules.

    Self-locates src/ via $PSScriptRoot and operates relative to it (matches
    the Makefile + CI's relative-path assumptions). Works identically whether
    invoked as `.\build.ps1 build` from src\ or `.\src\build.ps1 build` from the
    repo root.

.PARAMETER Target
    The target to run. Defaults to 'build'. One of:
      build, all            dll + launcher + stage-mod_loader + stage-legal
      dll                   Rust staticlib + C shell + MinHook -> relay_shell.dll
      launcher              -> mod_relay.exe
      stage-mod_loader      runtime Lua modules -> bin\mod_loader\
      stage-legal           LICENSE + THIRD_PARTY_NOTICES.md -> bin\
      check                 verify relay_shell.dll is a valid PE with the
                            production seam (DllMain + relay_discover +
                            relay_discover_detail; test-only symbol absent)
      c-tests               build + run the 6 C unit-test exes
      mod-loader-test       luajit mod_loader/tests/runner.lua (offline)
      test                  c-tests + cargo test + mod-loader-test
      clean                 cargo clean + remove bin\

.EXAMPLE
    .\build.ps1
    .\build.ps1 build
    .\build.ps1 check
    .\build.ps1 test

.NOTES
    Prerequisites (all on PATH): VS Build Tools 2022 (VCTools workload),
    Rust via rustup (MSVC host, x86_64-pc-windows-msvc target), LuaJIT 2.1.
    This script assumes the toolchain is already on PATH — it does NOT refresh
    PATH from the registry. If you just installed one of these tools in the
    current session, open a new shell (or reboot) so the new PATH takes effect
    before running this script. (Same assumption src/Makefile makes about
    luajit/cargo/etc.)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target = 'build'
)

# Product version: build-injected from the release-please manifest so
# --version reports it (matches the Makefile + CI). Read once at startup and
# published into the process env so any cmd /c child inherits it (used by the
# launcher, shell, and launcher_test compiles via
# /DRELAY_VERSION=\"%RELAY_VERSION%\").
# Fall back to '0.0.0-dev' if the manifest is missing or '.src' is empty.
# Resolves the manifest from $PSScriptRoot (always src/) so it works whether
# the script is invoked from src\ or the repo root — the read happens before
# the Push-Location below.
function Get-RelayVersion {
    $manifest = Join-Path (Join-Path $PSScriptRoot '..') '.release-please-manifest.json'
    if (Test-Path -LiteralPath $manifest) {
        try {
            $json = Get-Content -Raw -LiteralPath $manifest |
                ConvertFrom-Json -ErrorAction Stop
            if ($json.src) { return [string]$json.src }
        } catch { }
    }
    return '0.0.0-dev'
}
$env:RELAY_VERSION = Get-RelayVersion

# Derive numeric MAJOR/MINOR/PATCH for the rc.exe resource compiles (passed
# as /DRELAY_VERSION_MAJOR=... etc. so the .rc composes both the binary
# FILEVERSION 4-tuple AND the string FileVersion from the same numeric
# source - single source of truth, no drift). Strips any '-' pre-release
# suffix and defaults missing/non-numeric parts to 0, so the '0.0.0-dev'
# fallback degrades cleanly to (0, 0, 0). Published to $env: so the
# Invoke-WithVcvars cmd child inherits them (matches RELAY_VERSION itself).
function Get-RelayVersionPart {
    param([string]$Version, [int]$Index)
    $parts = $Version -split '\.'
    if ($Index -ge $parts.Length) { return '0' }
    $candidate = ($parts[$Index] -split '-')[0]
    if ($candidate -match '^\d+$') { return $candidate }
    return '0'
}
$env:RELAY_VERSION_MAJOR = Get-RelayVersionPart $env:RELAY_VERSION 0
$env:RELAY_VERSION_MINOR = Get-RelayVersionPart $env:RELAY_VERSION 1
$env:RELAY_VERSION_PATCH = Get-RelayVersionPart $env:RELAY_VERSION 2

# ---- Helpers --------------------------------------------------------------

# Locate vcvars64.bat via vswhere. Cached for the script run.
function Get-VcvarsPath {
    if ($script:CachedVcvars) { return $script:CachedVcvars }

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "vswhere not found at: $vswhere. Install Visual Studio Build Tools 2022 with the VCTools workload (Microsoft.VisualStudio.Workload.VCTools)."
    }
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $vsPath) {
        throw "No VS installation with VC Tools found. Install the VCTools workload (Microsoft.VisualStudio.Component.VC.Tools.x86.x64)."
    }
    $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path -LiteralPath $vcvars)) {
        throw "vcvars64.bat not found at: $vcvars"
    }

    $script:CachedVcvars = $vcvars
    return $vcvars
}

# Wrap one cl/link/dumpbin command. Writes the command to a temp .bat that
# loads vcvars (silenced) then runs the command. The .bat route is required
# (not `cmd /c "<inline>"`) because some commands embed `\"%RELAY_VERSION%\"`
# for /DRELAY_VERSION, and cmd's outer-quote-stripping rule for `cmd /c
# "string"` mis-parses the inner quotes — but cmd parses .bat files
# line-by-line, where quoted regions are handled per-token correctly.
function Invoke-WithVcvars {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$CaptureOutput
    )
    $vcvars = Get-VcvarsPath
    Write-Host ">>> $Command" -ForegroundColor DarkGray

    $tempBat = Join-Path $env:TEMP ("relay_build_{0}.bat" -f ([guid]::NewGuid()).ToString('N'))
    try {
        $batLines = @(
            '@echo off',
            "call `"$vcvars`" >nul 2>&1",
            $Command
        )
        # ASCII: cl/link/dumpbin args are pure ASCII; avoid a UTF-8 BOM that
        # cmd's batch parser would echo as the first line.
        Set-Content -LiteralPath $tempBat -Value $batLines -Encoding ASCII

        if ($CaptureOutput) {
            $output = & cmd /c $tempBat
            if ($LASTEXITCODE -ne 0) {
                throw "Command failed (exit $LASTEXITCODE): $Command"
            }
            return ,$output
        } else {
            & cmd /c $tempBat
            if ($LASTEXITCODE -ne 0) {
                throw "Command failed (exit $LASTEXITCODE): $Command"
            }
        }
    } finally {
        Remove-Item -Force -LiteralPath $tempBat -ErrorAction SilentlyContinue
    }
}

# Ensure bin\ exists before any rule writes into it (mirrors the Makefile's
# order-only prereq idiom on $(BIN)).
function Ensure-Bin {
    if (-not (Test-Path -LiteralPath 'bin')) {
        New-Item -ItemType Directory -Path 'bin' | Out-Null
    }
}

# Ensure bin\obj\ exists before any cl /Fo:bin\obj\ redirection. Keeps .obj
# intermediates out of src\ (where cl emits them by default). bin\obj\ is
# gitignored as part of /src/bin/ and cleaned by `clean`.
function Ensure-ObjDir {
    if (-not (Test-Path -LiteralPath 'bin\obj')) {
        New-Item -ItemType Directory -Path 'bin\obj' | Out-Null
    }
}

# Assert the binary carries a non-empty VS_VERSION_INFO and that FileVersion
# matches $ExpectedVersion. Regression guard for a future change that drops
# the .res from the link command, removes the .rc, or breaks version
# extraction — all of which would silently ship a resource-less binary
# otherwise (the exact defect this PR fixes).
# The .rc composes FileVersion from RELAY_VERSION_MAJOR.MINOR.PATCH only
# (pre-release suffix stripped), so the comparison reduces $ExpectedVersion
# to that numeric form to hold in both normal and '0.0.0-dev' fallback cases.
function Assert-VersionInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )
    $expectedFileVersion = @(
        (Get-RelayVersionPart $ExpectedVersion 0),
        (Get-RelayVersionPart $ExpectedVersion 1),
        (Get-RelayVersionPart $ExpectedVersion 2)
    ) -join '.'

    # Resolve to an absolute path before handing to the .NET API. .NET path
    # resolution uses the process working directory, NOT PowerShell's cwd, so a
    # relative path like 'bin\relay_shell.dll' would mis-resolve when the script
    # is invoked from any cwd other than the one the .NET process started in
    # (Push-Location only changes PowerShell's cwd, not the process's).
    $fullPath = (Resolve-Path -LiteralPath $Path).Path
    $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($fullPath)
    foreach ($field in @('ProductName', 'FileVersion', 'OriginalFilename', 'FileDescription')) {
        $value = $vi.$field
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "CHECK FAIL: $Path VersionInfo.$field is empty (PE resources missing - was the .res dropped from the link command?)"
        }
    }
    if ($vi.FileVersion -ne $expectedFileVersion) {
        throw "CHECK FAIL: $Path FileVersion '$($vi.FileVersion)' != expected '$expectedFileVersion' (version injection broken?)"
    }
    Write-Host "OK: $Path has PE version resources (ProductName='$($vi.ProductName)', FileVersion='$($vi.FileVersion)')" -ForegroundColor Green
}

# ---- Targets --------------------------------------------------------------

function Invoke-Build {
    Write-Host "=== build: dll + launcher + stage-mod_loader + stage-legal ===" -ForegroundColor Cyan
    Invoke-Dll
    Invoke-Launcher
    Invoke-StageModLoader
    Invoke-StageLegal
    Write-Host "build: complete" -ForegroundColor Green
}

function Invoke-Dll {
    Write-Host "=== dll: Rust staticlib + C shell + MinHook -> bin\relay_shell.dll ===" -ForegroundColor Cyan
    Ensure-Bin
    Ensure-ObjDir

    # (a) Rust staticlib. The cc crate auto-discovers MSVC, so no vcvars.
    # CRITICAL: GitHub Actions `shell: powershell` prepends `$ErrorActionPreference = 'stop'`,
    # which causes PowerShell 5.1 to terminate on stderr records from native processes.
    # cargo writes normal progress to stderr, so a successful build would terminate
    # before $LASTEXITCODE is checked. Route through cmd /c with 2>&1 so cmd preserves
    # the native exit code while PS5 receives merged stdout+stderr.
    Write-Host "Building Rust staticlib (x86_64-pc-windows-msvc)..."
    cmd /c "cargo build --release -p relay-discovery --target x86_64-pc-windows-msvc 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed (exit $LASTEXITCODE)" }

    # Compile the C shell + MinHook sources.
    # /MD (dynamic CRT) is required because capstone-sys (built by the cc crate
    # inside the Rust staticlib) compiles with /MD; cl's default /MT causes
    # LNK2019/LNK4217 CRT-mismatch errors at link time.
    Write-Host "Compiling C shell + MinHook sources..."
    Invoke-WithVcvars 'cl /nologo /O2 /MD /DRELAY_VERSION=\"%RELAY_VERSION%\" /c /I shell\include /I shell\vendor\minhook\include /Fo:bin\obj\ shell\src\dllmain.c shell\src\log_sink.c shell\vendor\minhook\src\buffer.c shell\vendor\minhook\src\hook.c shell\vendor\minhook\src\trampoline.c shell\vendor\minhook\src\hde\hde64.c'

    Write-Host "Compiling trampoline (relay_trampoline.obj to avoid MinHook name clash)..."
    Invoke-WithVcvars 'cl /nologo /O2 /MD /DRELAY_VERSION=\"%RELAY_VERSION%\" /c /I shell\include shell\src\trampoline.c /Fo:bin\obj\relay_trampoline.obj'

    # Compile the PE version-info resource (VS_VERSION_INFO) for the shell
    # DLL. Numeric version parts come from %RELAY_VERSION_MAJOR/MINOR/PATCH%
    # set near Get-RelayVersion.
    Write-Host "Compiling shell resource (relay_shell.res)..."
    Invoke-WithVcvars 'rc /nologo /DRELAY_VERSION_MAJOR=%RELAY_VERSION_MAJOR% /DRELAY_VERSION_MINOR=%RELAY_VERSION_MINOR% /DRELAY_VERSION_PATCH=%RELAY_VERSION_PATCH% /fo bin\obj\relay_shell.res shell\src\relay_shell.rc'

    # Link the DLL against the Rust staticlib + system libs.
    # Explicit /EXPORT: entries are required because MSVC link /DLL does NOT
    # auto-export from input objects/libs (unlike mingw's -shared). Without these,
    # the DLL ships with zero exports. Mirror what mingw auto-exports.
    Write-Host "Linking bin\relay_shell.dll..."
    Invoke-WithVcvars 'link /nologo /DLL /OUT:bin\relay_shell.dll bin\obj\dllmain.obj bin\obj\log_sink.obj bin\obj\buffer.obj bin\obj\hook.obj bin\obj\trampoline.obj bin\obj\hde64.obj bin\obj\relay_trampoline.obj bin\obj\relay_shell.res target\x86_64-pc-windows-msvc\release\relay_discovery.lib psapi.lib kernel32.lib user32.lib ws2_32.lib userenv.lib bcrypt.lib ntdll.lib /NODEFAULTLIB:libgcc.lib /EXPORT:DllMain /EXPORT:relay_discover /EXPORT:relay_discover_detail'

    Write-Host "dll: complete" -ForegroundColor Green
}

function Invoke-Launcher {
    Write-Host "=== launcher: -> bin\mod_relay.exe ===" -ForegroundColor Cyan
    Ensure-Bin
    Ensure-ObjDir

    Write-Host "RELAY_VERSION = $env:RELAY_VERSION"
    # Compile the PE version-info resource (VS_VERSION_INFO) for the launcher
    # exe. Numeric version parts come from %RELAY_VERSION_MAJOR/MINOR/PATCH%
    # set near Get-RelayVersion.
    Write-Host "Compiling launcher resource (launcher.res)..."
    Invoke-WithVcvars 'rc /nologo /DRELAY_VERSION_MAJOR=%RELAY_VERSION_MAJOR% /DRELAY_VERSION_MINOR=%RELAY_VERSION_MINOR% /DRELAY_VERSION_PATCH=%RELAY_VERSION_PATCH% /fo bin\obj\launcher.res launcher\src\launcher.rc'

    # /DRELAY_VERSION=\"%RELAY_VERSION%\" - %RELAY_VERSION% is expanded by
    # cmd inside the temp .bat, and the backslash-escaped quotes are
    # interpreted by cl's CRT as literal " (matches CI cmd-line convention).
    # bin\obj\launcher.res is auto-detected by cl as a resource input and
    # forwarded to link, embedding VS_VERSION_INFO in the final exe.
    Invoke-WithVcvars 'cl /nologo /O2 /DRELAY_VERSION=\"%RELAY_VERSION%\" /Fo:bin\obj\ /Fe:bin\mod_relay.exe launcher\src\launcher.c bin\obj\launcher.res /link kernel32.lib'

    Write-Host "launcher: complete" -ForegroundColor Green
}

function Invoke-StageModLoader {
    Write-Host "=== stage-mod_loader: all runtime Lua modules -> bin\mod_loader\ ===" -ForegroundColor Cyan
    Ensure-Bin

    $dst = 'bin\mod_loader'
    if (-not (Test-Path -LiteralPath $dst)) {
        New-Item -ItemType Directory -Path $dst | Out-Null
    }
    # Clear stale .lua files so the staged dir is exactly the current module
    # set, never a superset carrying obsolete files (matches Makefile's
    # `rm -f $(MOD_LOADER_DIR)/*.lua`). Idempotent. This "wipe" half of
    # wipe+glob is what makes the staged dir exactly the source set.
    Remove-Item -Path "$dst\*.lua" -Force -ErrorAction SilentlyContinue

    # Runtime modules only — NOT the tests/ harness. Get-ChildItem -Path is
    # non-recursive by default; the *.lua glob matches files directly under
    # mod_loader/, never mod_loader/tests/*.lua. Combined with the
    # Remove-Item above, the staged dir is exactly the current source set —
    # new modules are picked up automatically (the previous explicit-list
    # approach drifted from source and shipped an incomplete mod_loader/
    # in v0.1.0).
    $src = 'mod_loader'
    $modules = Get-ChildItem -Path "$src\*.lua"
    if (-not $modules) { throw "No .lua files found in $src\" }
    Copy-Item -Path $modules.FullName -Destination $dst

    Write-Host "stage-mod_loader: $($modules.Count) modules staged" -ForegroundColor Green
}

function Invoke-StageLegal {
    Write-Host "=== stage-legal: LICENSE + THIRD_PARTY_NOTICES.md -> bin\ ===" -ForegroundColor Cyan
    Ensure-Bin

    # Mirror CI's "fails if any source file is missing".
    if (-not (Test-Path -LiteralPath '..\LICENSE')) {
        throw '..\LICENSE not found'
    }
    if (-not (Test-Path -LiteralPath '..\THIRD_PARTY_NOTICES.md')) {
        throw '..\THIRD_PARTY_NOTICES.md not found'
    }

    Copy-Item -LiteralPath '..\LICENSE' -Destination 'bin\'
    Copy-Item -LiteralPath '..\THIRD_PARTY_NOTICES.md' -Destination 'bin\'

    Write-Host "stage-legal: complete" -ForegroundColor Green
}

function Invoke-Check {
    Write-Host "=== check: verify bin\relay_shell.dll is a valid PE with the production seam + both binaries carry PE version resources ===" -ForegroundColor Cyan

    $dll = 'bin\relay_shell.dll'
    if (-not (Test-Path -LiteralPath $dll)) {
        throw "$dll not found. Run 'build' (or 'dll') first."
    }

    $launcher = 'bin\mod_relay.exe'
    if (-not (Test-Path -LiteralPath $launcher)) {
        throw "$launcher not found. Run 'build' (or 'launcher') first."
    }

    # (a) Valid PE: MZ header.
    $stream = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $dll).Path)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        $mz = $reader.ReadBytes(2)
        if ($mz.Length -lt 2 -or $mz[0] -ne 0x4D -or $mz[1] -ne 0x5A) {
            throw "CHECK FAIL: $dll is not a valid PE (no MZ header)"
        }
    } finally {
        $stream.Close()
    }
    Write-Host "OK: $dll is a valid PE (MZ header)" -ForegroundColor Green

    # (b) + (c) Export table via dumpbin. Mirror Makefile check: required
    # production symbols present, test-only symbol absent.
    $exports = Invoke-WithVcvars -Command "dumpbin /exports $dll" -CaptureOutput

    $hasDllMain        = $false
    $hasDiscover       = $false
    $hasDiscoverDetail = $false
    $hasTestBoundary   = $false
    foreach ($line in $exports) {
        if ($line -match 'DllMain') { $hasDllMain = $true }
        # 'relay_discover' must NOT match 'relay_discover_detail' —
        # anchor with a trailing non-identifier boundary.
        if ($line -match 'relay_discover([^a-zA-Z0-9_]|$)') { $hasDiscover = $true }
        if ($line -match 'relay_discover_detail') { $hasDiscoverDetail = $true }
        if ($line -match 'relay_test_panic_boundary') { $hasTestBoundary = $true }
    }

    if (-not $hasDllMain)        { throw "CHECK FAIL: DllMain not found in exports" }
    if (-not $hasDiscover)       { throw "CHECK FAIL: relay_discover not found in exports" }
    if (-not $hasDiscoverDetail) { throw "CHECK FAIL: relay_discover_detail not found in exports" }
    Write-Host "OK: DllMain + relay_discover + relay_discover_detail present in exports" -ForegroundColor Green

    if ($hasTestBoundary) {
        throw "CHECK FAIL: relay_test_panic_boundary leaked into release (built with --features test-hooks?)"
    }
    Write-Host "OK: test-only symbol relay_test_panic_boundary absent from exports" -ForegroundColor Green

    # (d) Version-info resources: assert VS_VERSION_INFO is embedded in both
    # production binaries. Catches a regression where the .res is dropped from
    # the link command, the .rc is removed, or version extraction silently
    # breaks - all of which would otherwise ship a resource-less binary (the
    # defect this guard exists for).
    Assert-VersionInfo -Path $dll -ExpectedVersion $env:RELAY_VERSION
    Assert-VersionInfo -Path $launcher -ExpectedVersion $env:RELAY_VERSION

    Write-Host "check: PASS" -ForegroundColor Green
}

function Invoke-CTests {
    Write-Host "=== c-tests: build + run the 6 C unit-test exes ===" -ForegroundColor Cyan
    Ensure-Bin
    Ensure-ObjDir

    # Test infrastructure objects. launcher_test carries /DRELAY_TEST_BUILD
    # and the build-injected /DRELAY_VERSION (matches Makefile + CI).
    Write-Host "Building test infrastructure..."
    Invoke-WithVcvars 'cl /nologo /O2 /c /Fo:bin\obj\ tests\test_runner.c'
    Invoke-WithVcvars 'cl /nologo /O2 /DRELAY_TEST_BUILD /DRELAY_VERSION=\"%RELAY_VERSION%\" /I launcher\src /c launcher\src\launcher.c /Fo:bin\obj\launcher_test.obj'

    # Stubs for injection testing.
    Write-Host "Building stubs..."
    Invoke-WithVcvars 'cl /nologo /O2 /Fo:bin\obj\ /Fe:bin\stub_target.exe tests\stub_target.c /link /SUBSYSTEM:WINDOWS'
    Invoke-WithVcvars 'cl /nologo /O2 /c /Fo:bin\obj\ tests\stub_shell.c'
    Invoke-WithVcvars 'link /nologo /DLL /OUT:bin\stub_shell.dll bin\obj\stub_shell.obj kernel32.lib'

    # Test exes. shell32.lib provides CommandLineToArgvW (test_quoting oracle).
    Write-Host "Building test exes..."
    Invoke-WithVcvars 'cl /nologo /O2 /I launcher\src /Fo:bin\obj\ /Fe:bin\test_steam_env.exe tests\test_steam_env.c bin\obj\test_runner.obj bin\obj\launcher_test.obj kernel32.lib shell32.lib'
    Invoke-WithVcvars 'cl /nologo /O2 /I launcher\src /DRELAY_TEST_BUILD /Fo:bin\obj\ /Fe:bin\test_injection.exe tests\test_injection.c bin\obj\test_runner.obj bin\obj\launcher_test.obj kernel32.lib shell32.lib'
    Invoke-WithVcvars 'cl /nologo /O2 /I launcher\src /DRELAY_TEST_BUILD /Fo:bin\obj\ /Fe:bin\test_config.exe tests\test_config.c bin\obj\test_runner.obj bin\obj\launcher_test.obj kernel32.lib shell32.lib'
    Invoke-WithVcvars 'cl /nologo /O2 /I launcher\src /DRELAY_TEST_BUILD /Fo:bin\obj\ /Fe:bin\test_quoting.exe tests\test_quoting.c bin\obj\test_runner.obj bin\obj\launcher_test.obj kernel32.lib shell32.lib'
    Invoke-WithVcvars 'cl /nologo /O2 /DRELAY_VERSION=\"%RELAY_VERSION%\" /I shell\include /Fo:bin\obj\ /Fe:bin\test_trampoline.exe tests\test_trampoline.c bin\obj\test_runner.obj kernel32.lib'
    Invoke-WithVcvars 'cl /nologo /O2 /I shell\include /Fo:bin\obj\ /Fe:bin\test_log_sink.exe tests\test_log_sink.c bin\obj\test_runner.obj kernel32.lib'

    # Run each test exe directly (no wine on Windows native).
    # CRITICAL: GitHub Actions `shell: powershell` prepends `$ErrorActionPreference = 'stop'`,
    # which causes PowerShell 5.1 to terminate on stderr records from native processes.
    # Test failures write actionable output to stderr, and a failing test would terminate
    # before $LASTEXITCODE is checked. Route through cmd /c with 2>&1 so cmd preserves
    # the native exit code while PS5 receives merged stdout+stderr.
    Write-Host "=== C unit tests ==="
    foreach ($exe in @('test_steam_env', 'test_injection', 'test_config', 'test_quoting', 'test_trampoline', 'test_log_sink')) {
        Write-Host "--- $exe ---"
        cmd /c ".\bin\$exe.exe 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "$exe failed (exit $LASTEXITCODE)" }
    }

    Write-Host "c-tests: PASS" -ForegroundColor Green
}

function Invoke-ModLoaderTest {
    Write-Host "=== mod-loader-test: offline LuaJIT harness ===" -ForegroundColor Cyan

    # Hard-fail if luajit is absent (Makefile parity — no soft skip).
    $luajit = Get-Command luajit -ErrorAction SilentlyContinue
    if (-not $luajit) {
        throw "luajit not found on PATH. Install LuaJIT 2.1 (e.g. 'winget install DEVCOM.LuaJIT'). The mod loader test harness requires it."
    }

    # CRITICAL GOTCHA: runner.lua:13 computes its dirname via a forward-slash
    # regex (debug.getinfo(1,'S').source:sub(2):match('(.*/)')), so it MUST
    # be invoked with forward slashes from CWD=src/. A Windows backslash path
    # makes the match fail and tests can't find their sibling test_*.lua
    # files. Matches the Makefile invocation exactly.
    #
    # CRITICAL: GitHub Actions `shell: powershell` prepends `$ErrorActionPreference = 'stop'`,
    # which causes PowerShell 5.1 to terminate on stderr records from native processes.
    # Test failures write actionable output to stderr, and a failing test would terminate
    # before $LASTEXITCODE is checked. Route through cmd /c with 2>&1 so cmd preserves
    # the native exit code while PS5 receives merged stdout+stderr.
    cmd /c "luajit mod_loader/tests/runner.lua 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "mod loader tests failed (exit $LASTEXITCODE)" }

    Write-Host "mod-loader-test: PASS" -ForegroundColor Green
}

function Invoke-Test {
    Write-Host "=== test: c-tests + cargo test + mod-loader-test ===" -ForegroundColor Cyan
    Invoke-CTests

    Write-Host "=== Rust tests (cargo test --features test-hooks -p relay-discovery) ==="
    # CRITICAL: GitHub Actions `shell: powershell` prepends `$ErrorActionPreference = 'stop'`,
    # which causes PowerShell 5.1 to terminate on stderr records from native processes.
    # cargo test writes normal progress and failures to stderr, so a failing test run
    # would terminate before $LASTEXITCODE is checked. Route through cmd /c with 2>&1
    # so cmd preserves the native exit code while PS5 receives merged stdout+stderr.
    cmd /c "cargo test --features test-hooks -p relay-discovery 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "cargo test failed (exit $LASTEXITCODE)" }

    Invoke-ModLoaderTest

    Write-Host "test: PASS" -ForegroundColor Green
}

function Invoke-Clean {
    Write-Host "=== clean: cargo clean + remove bin\ ===" -ForegroundColor Cyan

    # CRITICAL: GitHub Actions `shell: powershell` prepends `$ErrorActionPreference = 'stop'`,
    # which causes PowerShell 5.1 to terminate on stderr records from native processes.
    # cargo clean writes normal progress to stderr, so a successful clean would terminate
    # before $LASTEXITCODE is checked. Route through cmd /c with 2>&1 so cmd preserves
    # the native exit code while PS5 receives merged stdout+stderr.
    cmd /c "cargo clean 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "cargo clean failed (exit $LASTEXITCODE)" }

    if (Test-Path -LiteralPath 'bin') {
        Remove-Item -Recurse -Force -LiteralPath 'bin'
    }

    Write-Host "clean: complete" -ForegroundColor Green
}

# ---- Main dispatch --------------------------------------------------------

# Self-locate src/ and operate relative to it (matches the Makefile + CI's
# relative-path assumptions). Push/Pop so the caller's CWD is restored even
# on error.
$SrcDir = $PSScriptRoot
Push-Location -LiteralPath $SrcDir
try {
    switch ($Target) {
        'build'            { Invoke-Build }
        'all'              { Invoke-Build }
        'dll'              { Invoke-Dll }
        'launcher'         { Invoke-Launcher }
        'stage-mod_loader' { Invoke-StageModLoader }
        'stage-legal'      { Invoke-StageLegal }
        'check'            { Invoke-Check }
        'c-tests'          { Invoke-CTests }
        'mod-loader-test'  { Invoke-ModLoaderTest }
        'test'             { Invoke-Test }
        'clean'            { Invoke-Clean }
        default {
            throw "Unknown target: '$Target'. Valid targets: build, all, dll, launcher, stage-mod_loader, stage-legal, check, c-tests, mod-loader-test, test, clean."
        }
    }
} finally {
    Pop-Location
}
