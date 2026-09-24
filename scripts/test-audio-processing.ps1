$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
if ($cmakeCommand) { $cmake = $cmakeCommand.Source } else {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $cmake = & $vswhere -latest -products '*' -find 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe' | Select-Object -First 1
}
if (-not $cmake) { throw 'Visual Studio CMake is required.' }
$testBuild = Join-Path $projectRoot 'build/native-audio-tests'
# Normalize the child environment: MSBuild rejects duplicate Path/PATH entries.
& $cmake -E env --unset=PATH --unset=Path "Path=$env:PATH" -- $cmake -S (Join-Path $projectRoot 'native/tests') -B $testBuild -A x64
if ($LASTEXITCODE -ne 0) { throw 'Native audio test configuration failed.' }
& $cmake -E env --unset=PATH --unset=Path "Path=$env:PATH" -- $cmake --build $testBuild --config Release
if ($LASTEXITCODE -ne 0) { throw 'Native audio test build failed.' }
& (Join-Path $testBuild 'Release/audio_processing_test.exe') (Join-Path $projectRoot 'native/third_party/rnnoise/rnnoise-model.bin')
if ($LASTEXITCODE -ne 0) { throw 'Native audio tests failed.' }
