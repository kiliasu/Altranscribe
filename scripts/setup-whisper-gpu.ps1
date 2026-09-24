# Official whisper.cpp Windows CUDA runtime. Models remain in their existing location.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$release = 'b5130'
$archiveName = 'whisper-cublas-12.4.0-bin-x64.zip'
$expectedHash = 'af520ddd034d985b55dfeea3e465ed93653ba2aee1a55e865033edc548c272a7'
$cache = Join-Path $projectRoot '.tools\downloads'
$destination = Join-Path $projectRoot ".tools\whisper-gpu\$release"
$archive = Join-Path $cache $archiveName
New-Item -ItemType Directory -Path $cache, $destination -Force | Out-Null
if (-not (Test-Path -LiteralPath $archive)) {
    Write-Output "Downloading whisper.cpp's CUDA build of whisper-server (674.5 MB); no model download."
    Invoke-WebRequest "https://github.com/ggml-org/whisper.cpp/releases/download/$release/$archiveName" -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) {
    throw "GPU runtime checksum mismatch: $archive"
}
if (-not (Get-ChildItem -LiteralPath $destination -Filter whisper-server.exe -Recurse -File)) {
    Expand-Archive -LiteralPath $archive -DestinationPath $destination
}
Get-ChildItem -LiteralPath $destination -Filter whisper-server.exe -Recurse -File | Select-Object -ExpandProperty FullName
