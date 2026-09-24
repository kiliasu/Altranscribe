param([switch]$Build, [switch]$Release, [switch]$Test, [string]$Device, [string]$Target = 'lib/main.dart')
$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
. (Join-Path $projectRoot 'scripts/development-tools.ps1')
$flutter = Get-FlutterCommand $projectRoot
$sdkRoot = Get-AndroidSdkDirectory $projectRoot
if (-not (Test-Path -LiteralPath (Join-Path $sdkRoot 'platforms/android-36/android.jar'))) {
    throw 'Install Android SDK platform 36 in the selected SDK, or run scripts/setup-android.ps1.'
}
$javaRoot = $env:JAVA_HOME
if (-not $javaRoot -or -not (Test-Path -LiteralPath (Join-Path $javaRoot 'bin/java.exe'))) {
    $javaExecutable = (Get-Command java -ErrorAction Stop).Source
    $javaRoot = Split-Path -Parent (Split-Path -Parent $javaExecutable)
}
$variables = @{
    ANDROID_HOME = $sdkRoot
    ANDROID_SDK_ROOT = $sdkRoot
    ANDROID_USER_HOME = Join-Path $projectRoot '.tools/runtime/adb'
    GRADLE_USER_HOME = Join-Path $projectRoot '.tools/gradle'
    JAVA_HOME = $javaRoot
    PUB_CACHE = Join-Path $projectRoot '.tools/pub-cache'
    APPDATA = Join-Path $projectRoot '.tools/runtime/roaming'
    LOCALAPPDATA = Join-Path $projectRoot '.tools/runtime/local'
    TEMP = Join-Path $projectRoot '.tools/runtime/tmp'
    TMP = Join-Path $projectRoot '.tools/runtime/tmp'
    FLUTTER_SUPPRESS_ANALYTICS = 'true'
    DASH__SUPPRESS_ANALYTICS = 'true'
}
$previous = @{}
foreach ($key in $variables.Keys) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
    [Environment]::SetEnvironmentVariable($key, $variables[$key], 'Process')
}
foreach ($key in @('ANDROID_USER_HOME', 'GRADLE_USER_HOME', 'PUB_CACHE', 'APPDATA', 'LOCALAPPDATA', 'TEMP')) {
    New-Item -ItemType Directory -Force -Path $variables[$key] | Out-Null
}
Push-Location $projectRoot
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependencies failed.' }
    if ($Test -and $Device) {
        & $flutter test $Target -d $Device --reporter expanded --no-uninstall
    } elseif ($Build) {
        & $flutter build apk $(if ($Release) { '--release' } else { '--debug' }) --target-platform android-arm64 -t $Target
    } elseif ($Device) {
        & $flutter run -d $Device --debug -t $Target
    } else {
        throw 'Specify -Build or -Device <adb serial>.'
    }
    if ($LASTEXITCODE -ne 0) { throw 'Android build or run failed.' }
} finally {
    Pop-Location
    foreach ($key in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process')
    }
}
