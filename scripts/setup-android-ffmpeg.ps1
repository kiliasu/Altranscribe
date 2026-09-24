$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'development-tools.ps1')
$sdkRoot = Get-AndroidSdkDirectory $projectRoot
$sourceRoot = Join-Path $projectRoot '.tools/ffmpeg-android'
$archive = Join-Path $sourceRoot 'ffmpeg-8.1.2.tar.xz'
$bash = Join-Path $env:ProgramFiles 'Git/bin/bash.exe'
if (-not (Test-Path -LiteralPath $bash)) { throw 'Git for Windows Bash is required.' }
New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
$makeRoot = Join-Path $sourceRoot 'make'
if (-not (Test-Path -LiteralPath (Join-Path $makeRoot 'usr/bin/make.exe'))) {
    New-Item -ItemType Directory -Path $makeRoot -Force | Out-Null
    $makeArchive = Join-Path $makeRoot 'make.tar.zst'
    Invoke-WebRequest 'https://repo.msys2.org/msys/x86_64/make-4.4.1-3-x86_64.pkg.tar.zst' -OutFile $makeArchive
    if ((Get-FileHash $makeArchive).Hash -ne 'AF0BDBA17F06FE037F0194069ADAA31A8FE45F1A11381501896AEA1FAE37BD5D') {
        throw 'GNU Make checksum mismatch.'
    }
    & "$env:SystemRoot/System32/tar.exe" -xf $makeArchive -C $makeRoot
    if ($LASTEXITCODE -ne 0) { throw 'GNU Make extraction failed.' }
}
if (-not (Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest 'https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz' -OutFile $archive
}
# Verified against the official release signature, key FCF986EA15E6E293A5644F10B4322F04D67658D8.
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne '464BEB5E7BF0C311E68B45AE2F04E9CC2AF88851ABB4082231742A74D97B524C') {
    throw 'FFmpeg source checksum mismatch.'
}
Push-Location $projectRoot
$previousInclude = $env:INCLUDE
$previousLib = $env:LIB
$previousSdk = $env:ANDROID_HOME
try {
    $env:ANDROID_HOME = $sdkRoot
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vsRoot = & $vswhere -latest -products '*' -property installationPath
    $msvc = Get-ChildItem (Join-Path $vsRoot 'VC/Tools/MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'
    $sdk = Get-ChildItem (Join-Path $kits 'Include') -Directory | Sort-Object Name -Descending | Select-Object -First 1
    $env:INCLUDE = "$($msvc.FullName)/include;$($sdk.FullName)/ucrt;$($sdk.FullName)/shared;$($sdk.FullName)/um"
    $env:LIB = "$($msvc.FullName)/lib/x64;$kits/Lib/$($sdk.Name)/ucrt/x64;$kits/Lib/$($sdk.Name)/um/x64"
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'ffmpeg-8.1.2/configure'))) {
        & $bash --noprofile --norc -c 'tar -xf .tools/ffmpeg-android/ffmpeg-8.1.2.tar.xz -C .tools/ffmpeg-android'
        if ($LASTEXITCODE -ne 0) { throw 'FFmpeg source extraction failed.' }
    }
    & $bash --noprofile --norc scripts/build-android-ffmpeg.sh
    if ($LASTEXITCODE -ne 0) { throw 'Android audio decoder build failed.' }
} finally { $env:INCLUDE = $previousInclude; $env:LIB = $previousLib; $env:ANDROID_HOME = $previousSdk; Pop-Location }
