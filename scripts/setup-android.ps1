$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$sdkRoot = Join-Path $projectRoot '.tools/android-sdk'
$archive = Join-Path $projectRoot '.tools/downloads/commandlinetools-win-15859902_latest.zip'
$toolsRoot = Join-Path $sdkRoot 'cmdline-tools/latest'
$sdkManager = Join-Path $toolsRoot 'bin/sdkmanager.bat'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $archive), $sdkRoot | Out-Null
if (-not (Test-Path -LiteralPath $sdkManager)) {
    if (-not (Test-Path -LiteralPath $archive)) {
        Invoke-WebRequest 'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip' -OutFile $archive
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne '90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a') {
        throw 'Android command-line tools checksum mismatch.'
    }
    Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $sdkRoot 'cmdline-tools') -Force
    $unpacked = [IO.Path]::GetFullPath((Join-Path $sdkRoot 'cmdline-tools/cmdline-tools'))
    $expectedRoot = [IO.Path]::GetFullPath($sdkRoot) + [IO.Path]::DirectorySeparatorChar
    if (-not $unpacked.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected SDK tools path.'
    }
    Move-Item -LiteralPath $unpacked -Destination $toolsRoot
}
$env:ANDROID_USER_HOME = Join-Path $projectRoot '.tools/runtime/adb'
$env:GRADLE_USER_HOME = Join-Path $projectRoot '.tools/gradle'
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
New-Item -ItemType Directory -Force -Path $env:ANDROID_USER_HOME, $env:GRADLE_USER_HOME | Out-Null
1..100 | ForEach-Object { 'y' } | & $sdkManager "--sdk_root=$sdkRoot" --licenses
if ($LASTEXITCODE -ne 0) { throw 'Android SDK license preparation failed.' }
& $sdkManager "--sdk_root=$sdkRoot" 'platforms;android-36' 'build-tools;36.0.0' 'platform-tools' 'ndk;28.2.13676358' 'cmake;3.22.1'
if ($LASTEXITCODE -ne 0) { throw 'Android SDK installation failed.' }
Write-Output "Android SDK ready: $sdkRoot"
