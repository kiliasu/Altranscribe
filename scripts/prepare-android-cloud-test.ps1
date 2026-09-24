param([Parameter(Mandatory)][string]$Device)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$adb = Join-Path $projectRoot '.tools/android-sdk/platform-tools/adb.exe'
$dataRoot = Join-Path $projectRoot '.tools/runtime/app-data'
$previousAdbHome = $env:ANDROID_USER_HOME
$env:ANDROID_USER_HOME = Join-Path $projectRoot '.tools/runtime/adb'
try {
    Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
    $keys = @{}
    foreach ($provider in @('openAI', 'gemini')) {
        $encrypted = [IO.File]::ReadAllBytes((Join-Path $dataRoot "$provider.credential"))
        $clear = [Security.Cryptography.ProtectedData]::Unprotect($encrypted, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $keys[$provider] = [Text.Encoding]::UTF8.GetString($clear)
        [Array]::Clear($clear)
    }
    # Transfer keys over the already authorized ADB connection into app-private
    # storage. No plaintext key is written on the PC or included in the APK, but
    # the keys stay in that storage until the test build is uninstalled.
    $start = [Diagnostics.ProcessStartInfo]::new($adb)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-s', $Device, 'shell', 'run-as', 'app.altranscribe', 'sh', '-c', '"cat > files/android-cloud.json"')) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    $process.StandardInput.WriteLine(($keys | ConvertTo-Json -Compress))
    $process.StandardInput.Close()
    $keys.Clear()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw 'Private credential transfer failed.' }
    $process.Dispose()
    $fixtureRoot = Join-Path $projectRoot '.tools/android-cloud-fixtures'
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    foreach ($rate in @(16000, 24000)) {
        $fixture = Join-Path $fixtureRoot "speech-$rate.pcm"
        & ffmpeg -hide_banner -loglevel error -y -i (Join-Path $dataRoot 'cloud-smoke/speech.wav') -ac 1 -ar $rate -f s16le $fixture
        if ($LASTEXITCODE -ne 0) { throw 'Synthetic speech conversion failed.' }
        & $adb -s $Device push $fixture "/data/local/tmp/altranscribe-cloud-$rate.pcm" | Out-Null
        & $adb -s $Device shell run-as app.altranscribe cp "/data/local/tmp/altranscribe-cloud-$rate.pcm" "files/cloud-speech-$rate.pcm"
        & $adb -s $Device shell rm "/data/local/tmp/altranscribe-cloud-$rate.pcm"
        if ($LASTEXITCODE -ne 0) { throw 'Speech fixture transfer failed.' }
    }
    Write-Output 'Android cloud test inputs prepared privately.'
} finally { $env:ANDROID_USER_HOME = $previousAdbHome }
