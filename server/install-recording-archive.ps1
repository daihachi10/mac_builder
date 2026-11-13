[CmdletBinding()]
param([Parameter(Mandatory)][string]$VoiceCodeDirectory)
$ErrorActionPreference = 'Stop'

$code = (Resolve-Path -LiteralPath $VoiceCodeDirectory).Path
$entry = Join-Path $code 'voice_web.py'
$python = Join-Path $code '.venv\Scripts\python.exe'
$archiveModule = Join-Path $code 'recording_archive.py'
$source = [IO.File]::ReadAllText($entry)
$anchor = 'install_mobile_api(app, globals())'
if (-not $source.Contains($anchor)) { throw 'Voice server entry point was not recognized.' }

if (-not $source.Contains('install_recording_archive(app,')) {
    $registration = @'
install_mobile_api(app, globals())
from recording_archive import install_recording_archive
install_recording_archive(app, AUDIO_RECEIVED / "device-archive", MIN_FREE_BYTES)
'@
    $updated = $source.Replace($anchor, $registration.TrimEnd())
} else {
    $updated = $source
}

& $python -c "import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))" (Join-Path $PSScriptRoot 'recording_archive.py')
if ($LASTEXITCODE -ne 0) { throw 'Archive module could not be parsed.' }
if ($updated -ne $source) { Copy-Item -LiteralPath $entry -Destination "$entry.before-recording-archive" }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'recording_archive.py') -Destination $archiveModule
if ($updated -ne $source) { [IO.File]::WriteAllText($entry, $updated, [Text.UTF8Encoding]::new($false)) }
