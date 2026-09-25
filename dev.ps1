param([switch]$Capture, [switch]$Verify, [switch]$Build, [switch]$Release, [switch]$Smoke, [switch]$CloudSmoke, [switch]$CaptionsSmoke, [switch]$RemoteSmoke, [switch]$Gpu, [string]$WhisperDirectory, [string]$TranslationModel, [string]$Target = 'lib/main.dart')
$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
. (Join-Path $projectRoot 'scripts/development-tools.ps1')
$flutter = Get-FlutterCommand $projectRoot
$localEnvironment = @{
    PUB_CACHE = Join-Path $projectRoot '.tools\pub-cache'
    APPDATA = Join-Path $projectRoot '.tools\runtime\roaming'
    LOCALAPPDATA = Join-Path $projectRoot '.tools\runtime\local'
    TEMP = Join-Path $projectRoot '.tools\runtime\tmp'
    TMP = Join-Path $projectRoot '.tools\runtime\tmp'
    FLUTTER_SUPPRESS_ANALYTICS = 'true'
    DASH__SUPPRESS_ANALYTICS = 'true'
    ALTRANSCRIBE_DATA_DIR = Join-Path $projectRoot '.tools\runtime\app-data'
    ALTRANSCRIBE_MODELS_DIR = Join-Path $projectRoot 'models'
    ALTRANSCRIBE_LOG_DIR = Join-Path $projectRoot '.tools\runtime\logs'
    CUDA_CACHE_PATH = Join-Path $projectRoot '.tools\runtime\cuda-cache'
}
if ($WhisperDirectory) { $localEnvironment.ALTRANSCRIBE_WHISPER_DIR = $WhisperDirectory }
if ($CloudSmoke) { $localEnvironment.ALTRANSCRIBE_CLOUD_SMOKE = '1' }
if ($Gpu) {
    $gpuExecutable = Join-Path $projectRoot '.tools\whisper-gpu\b5130\Release\whisper-server.exe'
    if (-not (Test-Path -LiteralPath $gpuExecutable)) { throw 'Run scripts/setup-whisper-gpu.ps1 first.' }
    $localEnvironment.ALTRANSCRIBE_WHISPER_EXECUTABLE = $gpuExecutable
    $localEnvironment.ALTRANSCRIBE_COMPUTE_MODE = 'gpu'
}
if ($TranslationModel) { $localEnvironment.ALTRANSCRIBE_TRANSLATION_MODEL = $TranslationModel }
$previousEnvironment = @{}
foreach ($name in $localEnvironment.Keys) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
foreach ($name in @('PUB_CACHE', 'APPDATA', 'LOCALAPPDATA', 'TEMP')) {
    New-Item -ItemType Directory -Path $localEnvironment[$name] -Force | Out-Null
}
Push-Location $projectRoot
try {
    foreach ($name in $localEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $localEnvironment[$name], 'Process')
    }
    $pubOutput = & $flutter pub get 2>&1
    $pubFailed = $LASTEXITCODE -ne 0
    if (-not $pubFailed -or "$pubOutput" -match 'Building with plugins requires symlink support') {
        # Directory junctions work without changing Windows Developer Mode. A dependency
        # change can leave the folder empty even though pub get itself succeeds.
        $pluginRoot = Join-Path $projectRoot 'windows/flutter/ephemeral/.plugin_symlinks'
        $plugins = Get-Content -LiteralPath '.flutter-plugins-dependencies' -Raw | ConvertFrom-Json
        foreach ($plugin in $plugins.plugins.windows) {
            $targetPath = [IO.Path]::GetFullPath($plugin.path)
            $linkPath = [IO.Path]::GetFullPath((Join-Path $pluginRoot $plugin.name))
            foreach ($checkedPath in @($targetPath, $linkPath)) {
                if (-not $checkedPath.StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Plugin link must stay inside this workspace.'
                }
            }
            if (-not (Test-Path -LiteralPath $linkPath)) {
                New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
            }
        }
        if ($pubFailed) { $pubOutput = & $flutter pub get 2>&1 }
    }
    if ($LASTEXITCODE -ne 0) {
        $pubOutput | Write-Output
        throw 'Flutter dependency preparation failed.'
    }
    if ($Verify) {
        # The pinned Flutter CLI truncates analyzer messages for non-ASCII paths.
        # Use its matching Dart analyzer directly, retaining fatal lint checks.
        $dart = Join-Path (Split-Path -Parent $flutter) 'dart.bat'
        & $dart analyze --fatal-infos
        if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed.' }
        & (Join-Path $projectRoot 'scripts/test-audio-processing.ps1')
    }
    if ($Build) {
        & $flutter build windows $(if ($Release) { '--release' } else { '--debug' })
    } elseif ($CaptionsSmoke) {
        & $flutter run -d windows --debug -t integration_test/caption_window_smoke.dart 2>&1 | Tee-Object -Variable captionSmokeOutput
        if (-not ($captionSmokeOutput -match '^CAPTION_SMOKE_PASSED$')) {
            throw 'Native caption window smoke test failed.'
        }
    } elseif ($RemoteSmoke) {
        & $flutter test integration_test/remote_test.dart -d windows --reporter expanded
    } elseif ($CloudSmoke) {
        & $flutter test integration_test/cloud_test.dart -d windows --reporter expanded
    } elseif ($Smoke) {
        & $flutter test integration_test/realtime_test.dart -d windows --reporter expanded
    } elseif ($Capture -or $Verify) {
        & $flutter test --reporter expanded
    } else {
        & $flutter run -d windows --debug -t $Target
    }
    if ($LASTEXITCODE -ne 0) { throw 'Flutter command failed.' }
} finally {
    Pop-Location
    foreach ($name in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
}
