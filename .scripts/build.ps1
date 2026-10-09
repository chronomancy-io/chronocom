Param(
    [string] $srcDirectory, # the path that contains the mod's .XCOM_sln (defaults to the repo root)
    [string] $sdkPath,      # the path to the SDK installation ending in "XCOM 2 War of the Chosen SDK"
    [string] $gamePath,     # the path to the XCOM 2 installation ending in "XCom2-WarOfTheChosen"
    [string] $config = "default" # build configuration: default | debug
)

$ScriptDirectory = Split-Path $MyInvocation.MyCommand.Path

if ([string]::IsNullOrEmpty($srcDirectory)) {
    $srcDirectory = Split-Path $ScriptDirectory
}

# Fall back to the Steam library that holds XCOM 2 when paths are not passed explicitly
if ([string]::IsNullOrEmpty($sdkPath) -or [string]::IsNullOrEmpty($gamePath)) {
    $steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    $libraries = @()
    if ($steamPath) {
        $libraries += $steamPath
        $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            $libraries += Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' |
                ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' }
        }
    }
    foreach ($lib in ($libraries | Select-Object -Unique)) {
        $common = Join-Path $lib 'steamapps\common'
        if ([string]::IsNullOrEmpty($sdkPath) -and (Test-Path "$common\XCOM 2 War of the Chosen SDK")) {
            $sdkPath = "$common\XCOM 2 War of the Chosen SDK"
        }
        if ([string]::IsNullOrEmpty($gamePath) -and (Test-Path "$common\XCOM 2\XCom2-WarOfTheChosen")) {
            $gamePath = "$common\XCOM 2\XCom2-WarOfTheChosen"
        }
    }
}

$common = Join-Path -Path $ScriptDirectory "X2ModBuildCommon\build_common.ps1"
Write-Host "Sourcing $common"
. ($common)

# Fails the build on any compiler warning in ChronoCOM's own source
. (Join-Path -Path $ScriptDirectory "build_strict.ps1")

function New-ChronoBuilder([string] $modName) {
    $b = [StrictBuildProject]::new($modName, $srcDirectory, $sdkPath, $gamePath)
    switch ($config)
    {
        "debug" {
            $b.EnableDebug()
        }
        "default" {
            # Nothing special
        }
        "" { ThrowFailure "Missing build configuration" }
        default { ThrowFailure "Unknown build configuration $config" }
    }
    return $b
}

$builder = New-ChronoBuilder "ChronoCOM"
$builder.InvokeBuild()

# Complexity gate: a function over the threshold fails the build like a warning does
& (Join-Path -Path $ScriptDirectory "complexity.ps1") -SrcRoot (Join-Path $srcDirectory "ChronoCOM\Src\ChronoCOM\Classes") -Threshold 4
if ($LASTEXITCODE -ne 0) { ThrowFailure "Cyclomatic complexity over the threshold in ChronoCOM" }

# InvokeBuild throws on failure. On success the last native command was Robocopy,
# whose exit code 1 means "files copied"; do not let it leak out as a failure.
exit 0
