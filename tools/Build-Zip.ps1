# =============================================================================
#  LHV Scan - build the download (LHV-Scan.zip)
# =============================================================================
#
#  Run:   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Zip.ps1
#
#  Packs the four files a pilot needs, plus a short README.txt, into
#  dist\LHV-Scan.zip. The scripts go in exactly as they are in this
#  repository: what you download is what you can read here.
# =============================================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
$work = Join-Path $dist 'LHV-Scan'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
[void](New-Item -ItemType Directory -Path $work -Force)

foreach ($name in 'Start.bat', 'LHV-Scan.ps1', 'scan-engine.ps1', 'scan-send.ps1') {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $work
}

$readme = @'
LHV Scan
========

1. Double-click Start.bat. The LHV Scan window opens.
2. Press "Scan now" and look at the list.
3. On your My sim page at LH Virtual, press "Connect the scan tool".
   Type the code into the tool and press "Send to My sim".

The tool only reads. Nothing in your simulator is changed, and nothing
is sent before you press Send. "Show what is sent" displays the exact text.

The three .ps1 files are the whole tool. You can open them with Notepad:
  scan-engine.ps1   reads your simulator       (never uses the internet)
  scan-send.ps1     sends the list             (the only internet use)
  LHV-Scan.ps1      the window

The source code is public: https://github.com/LH-Virtual/lhv-scan
'@
[System.IO.File]::WriteAllText((Join-Path $work 'README.txt'), ($readme -replace "`r?`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

$zip = Join-Path $dist 'LHV-Scan.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
# Entry names are written with forward slashes, as the ZIP format asks for.
$archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in (Get-ChildItem -LiteralPath $work -File | Sort-Object Name)) {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, "LHV-Scan/$($file.Name)", [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $archive.Dispose()
}
Remove-Item -LiteralPath $work -Recurse -Force
"Built $zip ($((Get-Item -LiteralPath $zip).Length) bytes)"
