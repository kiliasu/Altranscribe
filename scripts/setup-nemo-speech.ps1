# Official NeMo-Speech.cpp Windows CUDA runtime for Nemotron 3.5 Transcribe.
# The model is downloaded separately, in the app's model settings.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$release = '0.3.0'
$archiveName = "nemo-speech-$release-windows-x86_64-cuda.zip"
$expectedHash = 'd0d32ae1bf6ee0534767a47b2aa0e9e2ff6fe39643465c0baae9301d04f6ed42'
$cache = Join-Path $projectRoot '.tools\downloads'
$destination = Join-Path $projectRoot ".tools\nemo-speech\$release"
$archive = Join-Path $cache $archiveName
New-Item -ItemType Directory -Path $cache, $destination -Force | Out-Null
if (-not (Test-Path -LiteralPath $archive)) {
    Write-Output "Downloading NeMo-Speech.cpp's CUDA build (508.6 MB); no model download."
    Invoke-WebRequest "https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v$release/$archiveName" -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
    throw "NeMo-Speech.cpp checksum mismatch: $archive"
}
if (-not (Get-ChildItem -LiteralPath $destination -Filter nemo-speech.exe -Recurse -File)) {
    Expand-Archive -LiteralPath $archive -DestinationPath $destination
}
Get-ChildItem -LiteralPath $destination -Filter nemo-speech.exe -Recurse -File | Select-Object -ExpandProperty FullName
