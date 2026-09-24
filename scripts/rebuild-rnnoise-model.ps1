$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$cache = Join-Path $projectRoot '.tools/rnnoise-model-build'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$archive = Join-Path $cache 'model.tar.gz'
Invoke-WebRequest 'https://media.xiph.org/rnnoise/models/rnnoise_data-0b50c45.tar.gz' -OutFile $archive
if ((Get-FileHash $archive).Hash -ne '4AC81C5C0884EC4BD5907026AAAE16209B7B76CD9D7F71AF582094A2F98F4B43') { throw 'Model archive checksum mismatch.' }
& tar -xzf $archive -C $cache src/rnnoise_data.c src/rnnoise_data.h
if ($LASTEXITCODE -ne 0) { throw 'Model extraction failed.' }
$writer = (Invoke-WebRequest 'https://raw.githubusercontent.com/xiph/rnnoise/904a876dce1f9ab8860c0a5000ed151f9f6eef58/src/write_weights.c').Content
$writer.Replace('"weights_blob.bin", "w"', '"weights_blob.bin", "wb"') | Set-Content (Join-Path $cache 'write_weights.c')
@'
cmake_minimum_required(VERSION 3.14)
project(rnnoise_model_writer LANGUAGES C)
add_executable(model_writer write_weights.c)
target_include_directories(model_writer PRIVATE src ../../native/third_party/rnnoise/src)
target_compile_definitions(model_writer PRIVATE DUMP_BINARY_WEIGHTS _CRT_SECURE_NO_WARNINGS)
if(MSVC)
  target_compile_options(model_writer PRIVATE /wd4305)
endif()
'@ | Set-Content (Join-Path $cache 'CMakeLists.txt')
$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
if ($cmakeCommand) { $cmake = $cmakeCommand.Source } else {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $cmake = & $vswhere -latest -products '*' -find 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe' | Select-Object -First 1
}
if (-not $cmake) { throw 'Visual Studio CMake is required.' }
& $cmake -S $cache -B (Join-Path $cache 'build') -A x64
if ($LASTEXITCODE -ne 0) { throw 'Model writer configuration failed.' }
& $cmake --build (Join-Path $cache 'build') --config Release
if ($LASTEXITCODE -ne 0) { throw 'Model writer build failed.' }
Push-Location $cache
try {
    & ./build/Release/model_writer.exe
    if ($LASTEXITCODE -ne 0) { throw 'Model generation failed.' }
    if ((Get-FileHash weights_blob.bin).Hash -ne '35DA861B090C25DF53BA7F258B1EA55B1EA36D0C9063D9495BC145ADA945C90E') { throw 'Generated model checksum mismatch.' }
    Copy-Item -LiteralPath weights_blob.bin -Destination (Join-Path $projectRoot 'native/third_party/rnnoise/rnnoise-model.bin')
} finally { Pop-Location }
