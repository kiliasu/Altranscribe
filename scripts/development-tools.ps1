function Get-FlutterCommand([string]$ProjectRoot) {
    $bundled = Join-Path $ProjectRoot '.tools/flutter/bin/flutter.bat'
    if (Test-Path -LiteralPath $bundled) { return $bundled }
    $installed = Get-Command flutter -ErrorAction SilentlyContinue
    if ($installed) { return $installed.Source }
    throw 'Install Flutter 3.47.3 and add its bin directory to PATH, or place it in .tools/flutter.'
}

function Get-AndroidSdkDirectory([string]$ProjectRoot) {
    # Match Flutter's configured SDK before considering environment/default paths.
    $settingsFile = Join-Path $env:USERPROFILE '.flutter_settings'
    $configured = $null
    if (Test-Path -LiteralPath $settingsFile) {
        $configured = (Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json).'android-sdk'
    }
    foreach ($candidate in @($configured, $env:ANDROID_HOME, $env:ANDROID_SDK_ROOT,
        (Join-Path $ProjectRoot '.tools/android-sdk'),
        (Join-Path $env:LOCALAPPDATA 'Android/Sdk'))) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'platform-tools/adb.exe'))) {
            return [IO.Path]::GetFullPath($candidate)
        }
        if ($candidate -and $candidate -eq $configured) {
            throw 'The SDK selected by flutter config is missing. Correct it with flutter config --android-sdk <path>.'
        }
    }
    throw 'Install the Android SDK and set ANDROID_HOME, or run scripts/setup-android.ps1.'
}
