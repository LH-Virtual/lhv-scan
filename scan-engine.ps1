# =============================================================================
#  LHV Scan - the reading part ("engine")
# =============================================================================
#
#  This file contains every function that LOOKS at your simulator.
#  The window you see (LHV-Scan.ps1) only shows what these functions return.
#
#  WHAT THESE FUNCTIONS DO
#    They find your flight simulators, walk through the add-on folders and
#    read a few small facts from each add-on:
#      - what kind of add-on it is (airport, aircraft, livery, mod ...)
#      - for an airport scenery: which airport(s) it contains (ICAO codes)
#      - for an aircraft: which aircraft type it is (ICAO type, e.g. A320)
#
#  WHAT THESE FUNCTIONS NEVER DO
#    - They never change, move or delete anything in your simulator.
#    - They never connect to the internet. (Sending lives in its own file,
#      scan-send.ps1, and only happens when you press the button.)
#    - They never read your documents, your user name or your sim settings,
#      except the ONE line that says where your add-ons are installed.
#
#  WHICH FILES ARE OPENED, EXACTLY
#    UserCfg.opt            one line: where MSFS keeps its add-ons
#    x-plane_install_NN.txt one line: where X-Plane is installed
#    manifest.json          type, title, maker, creator, version of an MSFS add-on
#    layout.json            the list of file NAMES inside an MSFS add-on
#    *.bgl                  only the airport codes stored in a scenery file
#    aircraft.cfg           three lines: aircraft type, title, "is a livery"
#    apt.dat                the airport codes of an X-Plane scenery
#    *.acf                  one line: the aircraft type of an X-Plane aircraft
#
#  Besides the files, two facts about FOLDERS are looked at: where a linked
#  add-on folder points to (to find the add-on library behind it), and the
#  date an add-on folder was created (that is the day it was installed).
#
#  Everything is plain text. Lines starting with # are explanations.
#  Works with the Windows PowerShell that is part of Windows 10 and 11.
# =============================================================================

# The version of this tool and of the file it writes.
$script:LhvScanVersion = '1.1.0'
$script:LhvFileFormat  = 'lhv-addons/2'

# -----------------------------------------------------------------------------
#  Limits. They keep the scan quick and stop it from running away on a
#  broken or unusually large add-on.
# -----------------------------------------------------------------------------
$script:MaxFilesPerAddon   = 400    # scenery/aircraft files looked at per add-on
$script:MaxAirportsPerFile = 20000  # airport records read from one scenery file
$script:PackSize           = 12     # more airports than this = "a pack", not one airport
$script:TinyAddonFiles     = 5      # an "airport" with this few files is probably a fix
$script:ManyTypes          = 8      # more aircraft types than this = traffic models, not one aircraft
$script:LibraryDepth       = 3      # how many folder levels deep an add-on library is searched
$script:MaxLibraryFolders  = 5000   # folders looked at per library, at most (a whole drive would take ages)
$script:MovingDayLimit     = 15     # more add-ons "installed" on one day than this = moved, not installed
$script:MaxVersionLength   = 30     # longest version text that is kept

# The simulator name for a folder you added when no MSFS was found on this PC.
$script:LhvNoSimName = 'Added folder'

# =============================================================================
#  PART 1 - AIRPORT CODES INSIDE A SCENERY FILE (.bgl)
# =============================================================================

# -----------------------------------------------------------------------------
#  ConvertFrom-LhvIcaoCode
#  The simulator stores an airport code as ONE number instead of letters.
#  This turns the number back into text, e.g. 900199 -> "EDDF".
#
#  How the number is built (documented format of the simulator):
#    it is a number in base 38, where 0 = blank, 2..11 = "0".."9" and
#    12..37 = "A".."Z". "EDDF" is ((16*38 + 15)*38 + 15)*38 + 17 = 900199.
#
#  Input : the number, already without the extra low bits (see below).
#  Output: the code as text ("" if the number is not a valid code).
# -----------------------------------------------------------------------------
function ConvertFrom-LhvIcaoCode([int64]$number) {
    $value = $number
    $text  = ''
    while ($value -gt 0) {
        $digit = 0
        $value = [System.Math]::DivRem($value, [int64]38, [ref]$digit)
        if     ($digit -eq 0)                    { $char = ' ' }
        elseif ($digit -ge 2 -and $digit -le 11) { $char = [char](48 + $digit - 2) }    # 0-9
        elseif ($digit -ge 12)                   { $char = [char](65 + $digit - 12) }   # A-Z
        else                                     { return '' }                          # 1 is unused
        $text = "$char$text"
        if ($text.Length -gt 8) { return '' }
    }
    return $text.Trim()
}

# -----------------------------------------------------------------------------
#  Read-LhvAirportCode
#  Reads the code of ONE airport record. There are two layouts:
#
#    older add-ons (FSX style and MSFS 2020):
#        a 4-byte number at byte 0x28 of the record; its lowest 5 bits are
#        not part of the code.
#    add-ons built for MSFS 2024:
#        the old place is empty; an 8-byte number at byte 0x4C holds the
#        code; its lowest 6 bits are not part of the code.
#
#  Both were checked against real add-ons (EDDH in the old layout, EDDB in
#  the new one).
#
#  Input : the open file, where the record starts, how long it is.
#  Output: the code as text, or "".
# -----------------------------------------------------------------------------
function Read-LhvAirportCode($stream, $reader, [int64]$recordStart, [int64]$recordSize) {
    $stream.Position = $recordStart + 0x28
    $old = $reader.ReadUInt32()
    if ($old -ne 0) {
        $code = ConvertFrom-LhvIcaoCode ([int64]($old -shr 5))
        if ($code -cmatch '^[A-Z0-9]{3,8}$') { return $code }
    }
    if ($recordSize -ge 0x54) {
        $stream.Position = $recordStart + 0x4C
        $new = $reader.ReadUInt64()
        if ($new -ne 0 -and $new -lt 0x4000000000000000) {
            $code = ConvertFrom-LhvIcaoCode ([int64]($new -shr 6))
            if ($code -cmatch '^[A-Z0-9]{3,8}$') { return $code }
        }
    }
    return ''
}

# -----------------------------------------------------------------------------
#  Read-LhvBglAirports
#  Reads the airport codes stored in ONE scenery file (.bgl).
#
#  A .bgl file starts with a small table of contents: "sections". Each section
#  has a type; type 3 is "airports". We jump straight to the airport section
#  and read one number per airport (its code, see Read-LhvAirportCode).
#  Nothing else in the file is read: no buildings, no textures, no coordinates.
#
#  Input : full path of a .bgl file.
#  Output: a list of airport codes, e.g. @("EDDH"). Empty if the file has no
#          airports (object libraries, tree fixes, landmarks ...) or is not a
#          scenery file at all.
# -----------------------------------------------------------------------------
function Read-LhvBglAirports([string]$file) {
    $codes  = New-Object System.Collections.Generic.List[string]
    $stream = $null
    try {
        # Open for reading only, and let the simulator keep using the file.
        $stream = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Open,
                      [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.BinaryReader($stream)
        $length = $stream.Length
        if ($length -lt 0x38) { return $codes.ToArray() }

        # The first four bytes identify a scenery file.
        if ($reader.ReadUInt32() -ne 0x19920201) { return $codes.ToArray() }
        $headerSize = $reader.ReadUInt32()                 # normally 0x38
        $stream.Position = 0x14
        $sectionCount = $reader.ReadUInt32()
        if ($headerSize -lt 0x38 -or $headerSize -gt 0x400 -or $sectionCount -gt 4096) { return $codes.ToArray() }

        # Walk the table of contents: 20 bytes per section.
        for ($s = 0; $s -lt $sectionCount; $s++) {
            $stream.Position = $headerSize + ($s * 20)
            if ($stream.Position + 20 -gt $length) { break }
            $type      = $reader.ReadUInt32()
            $sizeFlag  = $reader.ReadUInt32()
            $subCount  = $reader.ReadUInt32()
            $subOffset = $reader.ReadUInt32()
            [void]$reader.ReadUInt32()                     # total size, not needed

            if ($type -ne 0x03) { continue }               # 3 = airports; skip everything else

            # A sub-section entry is 16 or 20 bytes long, depending on this flag.
            $entrySize = (($sizeFlag -band 0x10000) -bor 0x40000) -shr 0x0E
            for ($i = 0; $i -lt $subCount; $i++) {
                $at = [int64]$subOffset + ([int64]$i * $entrySize)
                if ($at + $entrySize -gt $length) { break }
                $stream.Position = $at + ($entrySize - 12) # skip the map-tile numbers
                $recordCount = $reader.ReadUInt32()
                $dataOffset  = [int64]$reader.ReadUInt32()

                # Each airport record: 2 bytes "kind", 4 bytes "size", then data.
                $pos = $dataOffset
                for ($r = 0; $r -lt $recordCount; $r++) {
                    if ($pos + 0x2C -gt $length -or $codes.Count -ge $script:MaxAirportsPerFile) { break }
                    $stream.Position = $pos + 2
                    $recordSize = [int64]$reader.ReadUInt32()
                    if ($recordSize -lt 0x2C -or $pos + $recordSize -gt $length) { break }   # not an airport record: stop
                    $code = Read-LhvAirportCode $stream $reader $pos $recordSize
                    if ($code -and -not $codes.Contains($code)) { $codes.Add($code) }
                    $pos += $recordSize
                }
            }
        }
    } catch {
        # A file we cannot read is simply "no airports found". Nothing is changed.
    } finally {
        if ($stream) { $stream.Dispose() }
    }
    return $codes.ToArray()
}

# =============================================================================
#  PART 2 - SMALL TEXT FILES OF AN ADD-ON
# =============================================================================

# -----------------------------------------------------------------------------
#  Read-LhvManifest
#  Reads five fields from an MSFS add-on's manifest.json.
#  "version" is package_version: the maker raises it with every update, so a
#  changed version means the add-on was updated.
#  Input : the add-on folder.
#  Output: @{ type; title; maker; creator; version } or $null if there is no
#          manifest (then the folder is not an MSFS add-on).
# -----------------------------------------------------------------------------
function Read-LhvManifest([string]$folder) {
    $path = Join-Path $folder 'manifest.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $m = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        # Only a text counts as a version; a number, list or object written by
        # mistake would otherwise turn into PowerShell's own text for it.
        $version = ''
        if ($m.package_version -is [string]) { $version = $m.package_version.Trim() }
        if ($version.Length -gt $script:MaxVersionLength) { $version = $version.Substring(0, $script:MaxVersionLength) }
        return @{ type    = "$($m.content_type)".ToUpper()
                  title   = "$($m.title)"
                  maker   = "$($m.manufacturer)"
                  creator = "$($m.creator)"
                  version = $version }
    } catch {
        # Broken manifest: we still know it is an add-on, just not which kind.
        return @{ type = 'UNKNOWN'; title = ''; maker = ''; creator = ''; version = '' }
    }
}

# -----------------------------------------------------------------------------
#  Get-LhvLinkTarget
#  Add-on managers (Addons Linker, FSDT Addon Manager ...) keep the add-ons in
#  a folder of their own and put only a LINK into Community (a "symbolic
#  link" or a "junction"). Windows follows such a link by itself when a file
#  inside is read. This function only asks where the link points to.
#
#  Input : a folder.
#  Output: the full path the link points to, or "" if the folder is a normal
#          folder (or the link cannot be read).
# -----------------------------------------------------------------------------
function Get-LhvLinkTarget([string]$folder) {
    try {
        # Quick check first: only links carry the "reparse point" mark (0x400).
        $info = New-Object System.IO.DirectoryInfo($folder)
        if (-not $info.Exists) { return '' }
        if (([int]$info.Attributes -band 0x400) -eq 0) { return '' }
        $item = Get-Item -LiteralPath $folder -Force
        if ($item.LinkType -ne 'SymbolicLink' -and $item.LinkType -ne 'Junction') { return '' }
        $target = "$(@($item.Target)[0])"
        if (-not $target) { return '' }
        # Windows sometimes writes the long-path form (\\?\D:\..., \\?\UNC\server\...).
        $target = $target -replace '^\\\\\?\\UNC\\', '\\' -replace '^\\(\\|\?)\?\\', ''
        # A symbolic link may point to a place relative to where the link is.
        if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path $folder -Parent) $target }
        return (ConvertTo-LhvFolderKey $target)
    } catch {
        return ''
    }
}

# -----------------------------------------------------------------------------
#  ConvertTo-LhvFolderKey
#  Writes a folder path in one way only (full path, no "\" at the end), so
#  that two ways of writing the same folder are recognised as one.
# -----------------------------------------------------------------------------
function ConvertTo-LhvFolderKey([string]$path) {
    $full = [System.IO.Path]::GetFullPath(($path -replace '^\\\\\?\\UNC\\', '\\' -replace '^\\(\\|\?)\?\\', ''))
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }     # keep "D:\" as it is
    return $full
}

# -----------------------------------------------------------------------------
#  Split-LhvFolder / Join-LhvFolder
#  A folder path as its ROOT (a drive "D:" or a network share
#  "\\server\share") and the list of folder names below it, and back.
#  Used to find the folder that several paths have in common.
# -----------------------------------------------------------------------------
function Split-LhvFolder([string]$path) {
    $root = ''
    if     ($path -match '^(\\\\[^\\]+\\[^\\]+)') { $root = $matches[1] }
    elseif ($path -match '^([A-Za-z]:)')           { $root = $matches[1] }
    $parts = @($path.Substring($root.Length) -split '\\' | Where-Object { $_ })
    return @{ root = $root; parts = $parts }
}

function Join-LhvFolder([string]$root, $parts) {
    $names = @($parts | Where-Object { $_ })
    if ($names.Count -eq 0) {
        if ($root -match '^[A-Za-z]:$') { return "$root\" }
        return $root
    }
    return $root + '\' + ($names -join '\')
}

# -----------------------------------------------------------------------------
#  Test-LhvInsideFolder
#  Is $path the folder $folder itself, or somewhere inside it?
#  (Upper and lower case are the same, as everywhere in Windows.)
# -----------------------------------------------------------------------------
function Test-LhvInsideFolder([string]$path, [string]$folder) {
    $p = $path.TrimEnd('\'); $f = $folder.TrimEnd('\')
    if ($p.Equals($f, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith($f + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

# The folder names MSFS uses for its own add-on folders. A folder with one of
# these names (or anything inside it) is a simulator folder, never a library:
# its add-ons belong to the simulator it comes from.
$script:SimFolderNames = '^(Community|Community2024|Official\d*)$'

# -----------------------------------------------------------------------------
#  Test-LhvSimFolder
#  Does a path lie in a simulator folder: one of the real places of a
#  simulator found on this PC ($known), or a folder named like one
#  (Community, Community2024, Official...) - for example the Community
#  folder of an MSFS that was uninstalled but kept its add-ons?
# -----------------------------------------------------------------------------
function Test-LhvSimFolder([string]$path, [string[]]$known) {
    foreach ($k in @($known)) { if ($k -and (Test-LhvInsideFolder $path $k)) { return $true } }
    foreach ($name in @((Split-LhvFolder $path).parts)) { if ($name -match $script:SimFolderNames) { return $true } }
    return $false
}

# -----------------------------------------------------------------------------
#  Get-LhvProtectedFolders
#  Personal and system folders of this PC that are never searched as an
#  add-on library found through links (see Group-LhvLinkTargets): your user
#  folder and the folder above it (C:\Users), Documents, Downloads and
#  Desktop and the folders that hold them, Program Files (both),
#  ProgramData and Windows. Only the folder names are asked from Windows;
#  nothing inside them is opened.
#  Output: their full paths (each also as its real path, see
#          Resolve-LhvRealPath).
# -----------------------------------------------------------------------------
function Get-LhvProtectedFolders {
    $list = New-Object System.Collections.Generic.List[string]
    $add = {
        param($path)
        if (-not $path) { return }
        foreach ($key in @((ConvertTo-LhvFolderKey $path), (Resolve-LhvRealPath $path))) {
            if ($key -and -not ($list -contains $key)) { $list.Add($key) }      # -contains ignores case
        }
    }
    $userFolder = $env:USERPROFILE
    $shell = @()
    if ($userFolder) {
        & $add $userFolder
        & $add (Split-Path $userFolder -Parent)                                # C:\Users
        $shell += (Join-Path $userFolder 'Downloads'), (Join-Path $userFolder 'Documents'), (Join-Path $userFolder 'Desktop')
    }
    # Documents and Desktop can be moved elsewhere (for example into OneDrive).
    foreach ($name in 'MyDocuments', 'Desktop') {
        try { $shell += [Environment]::GetFolderPath($name) } catch { }
    }
    foreach ($folder in $shell) {
        if (-not $folder) { continue }
        & $add $folder
        & $add (Split-Path $folder -Parent)
    }
    foreach ($folder in $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramData, $env:windir) { & $add $folder }
    return $list.ToArray()
}

# -----------------------------------------------------------------------------
#  Resolve-LhvRealPath
#  The real place of a folder. A path can lead through a link anywhere on
#  the way (D:\MSFS -> E:\Games\MSFS). This replaces every link on the way by
#  where it points to, so that two spellings of the same folder compare equal.
#  (A drive made with "subst" is not resolved; it is rare for add-ons.)
#
#  Input : a folder path.
#  Output: its real full path, or "" if the path is not valid.
# -----------------------------------------------------------------------------
function Resolve-LhvRealPath([string]$path) {
    try { $current = ConvertTo-LhvFolderKey $path } catch { return '' }
    for ($round = 0; $round -lt 16; $round++) {                    # 16: a stop for links that point in a circle
        $split = Split-LhvFolder $current
        $parts = @($split.parts)
        $changed = $false
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $target = Get-LhvLinkTarget (Join-LhvFolder $split.root $parts[0..$i])
            if (-not $target) { continue }
            $rest = ''
            if ($i + 1 -lt $parts.Count) { $rest = '\' + ($parts[($i + 1)..($parts.Count - 1)] -join '\') }
            $current = ConvertTo-LhvFolderKey ($target.TrimEnd('\') + $rest)
            $changed = $true
            break
        }
        if (-not $changed) { return $current }
    }
    return $current
}

# -----------------------------------------------------------------------------
#  Get-LhvInstallDate
#  The day an add-on was installed: the date its folder was CREATED.
#  (The dates of the files inside are useless: they come from the maker's
#  archive, not from your PC. This was checked on a real simulator.)
#  For a linked add-on the date of the real folder is taken, not the date of
#  the link: the link is made again whenever the add-on manager switches the
#  add-on on.
#
#  Input : the add-on folder.
#  Output: the date as yyyy-MM-dd (local time), or "".
# -----------------------------------------------------------------------------
function Get-LhvInstallDate([string]$folder) {
    try {
        $real = Get-LhvLinkTarget $folder
        if (-not $real) { $real = $folder }
        $info = New-Object System.IO.DirectoryInfo($real)
        if (-not $info.Exists) { return '' }
        return $info.CreationTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return ''
    }
}

# -----------------------------------------------------------------------------
#  Get-LhvAddonFiles
#  Lists the files of an add-on whose NAME matches a pattern (e.g. "*.bgl").
#
#  MSFS add-ons carry a file list (layout.json). Reading that list is much
#  faster than opening every sub-folder, so it is tried first. If there is no
#  list, the folders are searched directly.
#
#  The list is written by whoever made the add-on, so it is not trusted: an
#  entry that points OUT of the add-on folder ("..\..\somewhere else") is
#  skipped. The tool only ever opens files inside the add-on it is reading.
#
#  Input : add-on folder, a regular expression for the file name.
#  Output: full paths, at most $script:MaxFilesPerAddon of them.
# -----------------------------------------------------------------------------
function Get-LhvAddonFiles([string]$folder, [string]$namePattern) {
    $files  = New-Object System.Collections.Generic.List[string]
    $layout = Join-Path $folder 'layout.json'
    if (Test-Path -LiteralPath $layout) {
        try {
            $inside = [System.IO.Path]::GetFullPath($folder).TrimEnd('\') + '\'
            $list = (Get-Content -LiteralPath $layout -Raw -Encoding UTF8 | ConvertFrom-Json).content
            foreach ($item in $list) {
                if ("$($item.path)" -match $namePattern) {
                    $full = [System.IO.Path]::GetFullPath((Join-Path $folder ("$($item.path)" -replace '/', '\')))
                    # Stay inside the add-on: no "..", no other drive, no network path.
                    if (-not $full.StartsWith($inside, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    if (Test-Path -LiteralPath $full) { $files.Add($full) }
                    if ($files.Count -ge $script:MaxFilesPerAddon) { break }
                }
            }
            if ($files.Count -gt 0) { return $files.ToArray() }
        } catch { }
    }
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($folder, '*', [System.IO.SearchOption]::AllDirectories)) {
            if ($f -match $namePattern) { $files.Add($f) }
            if ($files.Count -ge $script:MaxFilesPerAddon) { break }
        }
    } catch { }
    return $files.ToArray()
}

# -----------------------------------------------------------------------------
#  Get-LhvFileCount
#  How many files an MSFS add-on has, according to its own file list
#  (layout.json). Used to tell a full airport scenery from a small fix.
#  Output: the number of files, or 9999 if there is no file list.
# -----------------------------------------------------------------------------
function Get-LhvFileCount([string]$folder) {
    $layout = Join-Path $folder 'layout.json'
    if (-not (Test-Path -LiteralPath $layout)) { return 9999 }
    try { return @((Get-Content -LiteralPath $layout -Raw -Encoding UTF8 | ConvertFrom-Json).content).Count } catch { return 9999 }
}

# -----------------------------------------------------------------------------
#  ConvertTo-LhvTypeCode
#  Some aircraft do not write the official type code, only a model name such
#  as "A-320 CFM SL" or "A320 | IAE | SL". This takes the first word, removes
#  the hyphen and accepts it only if it looks like a type code (A320, B738,
#  E190, A35K). "777-300ER" is NOT turned into a code: that would be a guess.
#
#  Input : a model name from aircraft.cfg.
#  Output: a type code, or "" if the name does not contain one.
# -----------------------------------------------------------------------------
function ConvertTo-LhvTypeCode([string]$modelName) {
    $first = (("$modelName".Trim() -split '[\s|,;(]')[0]).ToUpper()
    $code  = $first -replace '^([A-Z]{1,2})-(\d)', '$1$2'      # "A-320" -> "A320"
    if ($code -cmatch '^[A-Z]{1,3}\d{2,3}[A-Z]?$' -and $code.Length -le 4) { return $code }
    return ''
}

# -----------------------------------------------------------------------------
#  Read-LhvAircraftCfg
#  Reads a few facts from an aircraft.cfg (a plain text settings file):
#    icao_type_designator   the official type code, e.g. B77W
#    icao_model, ui_type    a model name; used only if the code is missing
#    base_container         present only in a LIVERY (it points to the real aircraft)
#    title                  the name shown in the simulator
#  Input : full path of an aircraft.cfg.
#  Output: @{ icaoType; isLivery; title }
# -----------------------------------------------------------------------------
function Read-LhvAircraftCfg([string]$file) {
    $result = @{ icaoType = ''; isLivery = $false; title = '' }
    $fromModel = ''
    try {
        foreach ($line in [System.IO.File]::ReadLines($file)) {
            if ($line -match '^\s*icao_type_designator\s*=\s*"?\s*([A-Za-z0-9]{2,4})\b') {
                if (-not $result.icaoType) { $result.icaoType = $matches[1].ToUpper() }
            } elseif ($line -match '^\s*(icao_model|ui_type)\s*=\s*"?([^";]+)') {
                if (-not $fromModel) { $fromModel = ConvertTo-LhvTypeCode $matches[2] }
            } elseif ($line -match '^\s*base_container\s*=\s*"?\s*[^"\s;]') {
                $result.isLivery = $true
            } elseif ($line -match '^\s*title\s*=\s*"?([^";]+)') {
                if (-not $result.title) { $result.title = $matches[1].Trim() }
            }
        }
    } catch { }
    if (-not $result.icaoType) { $result.icaoType = $fromModel }
    return $result
}

# =============================================================================
#  PART 3 - WHAT KIND OF ADD-ON IS IT?
# =============================================================================

# -----------------------------------------------------------------------------
#  Get-LhvKindFromName
#  For add-ons that are neither an airport nor an aircraft, the name usually
#  says what they are. This looks for well-known words in the folder name and
#  title. It is only used AFTER the files said "no airport, no aircraft".
#
#  Input : folder name and title as one text.
#  Output: @{ kind; detail }  kind is one of: mod, library, traffic, navdata,
#          tool, part, other. detail is a short label for the window.
#          ("part" is shown as kind "other" in the result.)
# -----------------------------------------------------------------------------
function Get-LhvKindFromName([string]$text) {
    $t = $text.ToLower()
    # Order matters: the first match wins, so the specific words come first.
    # Words that are also part of airport names (London "City", Cam"bridge")
    # are left out on purpose: they would turn an airport into a mod.
    $rules = @(
        @{ kind = 'navdata'; detail = 'Navigation data';      words = 'navigraph|navdata|nav-data|airac' },
        @{ kind = 'traffic'; detail = 'AI traffic';           words = 'fsltl|\baig\b|aig-|traffic|\bai[-_ ]?(aircraft|models)|\bmtl\b|model[-_ ]?match|vessels|ships?[-_ ]|seafront' },
        @{ kind = 'mod';     detail = 'Tree fix';             words = 'tree[-_ ]?(fix|remov)|treefix|trees?[-_ ]?(fix|mod|height|replac|remov)|accusim.*trees|bijan' },
        @{ kind = 'mod';     detail = 'Seasons';              words = 'season|winter|autumn|snow[-_ ]?mod' },
        @{ kind = 'mod';     detail = 'Lighting';             words = 'light(s|ing)?[-_ ]?(fix|mod|pack|enhanc)|night[-_ ]?light|\bals\b|taxi[-_ ]?light|enhanced[-_ ]?airport[-_ ]?graphics|\beag\b' },
        @{ kind = 'mod';     detail = 'Terrain mesh';         words = 'mesh|terrain|\bdem\b|elevation' },
        @{ kind = 'mod';     detail = 'Photo scenery';        words = 'ortho|photo[-_ ]?(real|scenery)|aerial|satellite|photogrammetry' },
        @{ kind = 'mod';     detail = 'Landmarks or city';    words = 'landmark|cityscape|\bpoi\b|skyline' },
        @{ kind = 'mod';     detail = 'Jetways or ground';    words = 'jetway|gsx|ground[-_ ]?(service|handling)|markings?\b|pushback|marshall' },
        @{ kind = 'mod';     detail = 'Airport fix or tweak'; words = 'airport[-_ ]?(fix|patch|update)|(?<![a-z])fix(es)?\b|\bpatch\b|\bmod\b|performance|tweak|parking|\bils\b|afcad|korrektur|correction|verbesserung|bahnlicht' },
        @{ kind = 'part';    detail = 'Part of an aircraft (cabin, textures, sounds)'; words = 'cabin|compat|low[-_ ]?res|texture[-_ ]?(mod|pack)|sound[-_ ]?(mod|pack)|zcore' },
        @{ kind = 'library'; detail = 'Object library';       words = 'librar|\blib\b|[-_]lib[-_]?|objects?|assets|modellib|models|materials|textures|common|shared|effects' },
        @{ kind = 'tool';    detail = 'Tool or panel';        words = 'toolbar|panel|\befb\b|\bflow\b|vfrmap|kneeboard|fsuipc|simconnect|simbridge|\bbridge\b|connector|plugin' }
    )
    foreach ($rule in $rules) {
        if ($t -match $rule.words) { return @{ kind = $rule.kind; detail = $rule.detail } }
    }
    return @{ kind = 'other'; detail = '' }
}

# -----------------------------------------------------------------------------
#  Test-LhvBuiltIn
#  Is this add-on part of the simulator itself (made by Asobo or Microsoft)?
#  Those are not add-ons you installed, so they are left out.
# -----------------------------------------------------------------------------
function Test-LhvBuiltIn([string]$folderName, [string]$creator) {
    if ($creator -match '(?i)^\s*(asobo|microsoft)') { return $true }
    if ($folderName -match '(?i)^(asobo-|microsoft-|fs-base|fs24-|fs20-asobo-|fs\d+-asobo-)') { return $true }
    return $false
}

# -----------------------------------------------------------------------------
#  New-LhvEntry
#  One line of the result list. Every add-on becomes exactly one of these.
#
#    sim, source, folder    where it was found (never a full path, only names)
#                           source: community, marketplace, library,
#                           aircraft-folder or custom-scenery
#    type, title, maker, creator   from manifest.json (MSFS)
#    version   package_version from manifest.json (MSFS), "" if not known
#    installed the day the add-on folder was created, yyyy-MM-dd, "" if not
#              known (see Get-LhvInstallDate and Clear-LhvMovingDay)
#    kind      airport | aircraft | livery | mod | library | traffic |
#              navdata | tool | other
#    detail    a short label, e.g. "Tree fix"
#    icaos     airport codes found INSIDE the scenery files
#    aircraftTypes  aircraft type codes found in aircraft.cfg / .acf
#    certain   $true  = read from the add-on's own files
#              $false = not clear; the window offers "Quick fix" for it
#    fixed     $true  = you corrected it yourself with "Quick fix"
#    note      why it is not certain, in plain words
# -----------------------------------------------------------------------------
function New-LhvEntry([string]$sim, [string]$source, [string]$folder) {
    return [ordered]@{
        sim = $sim; source = $source; folder = $folder
        type = ''; title = ''; maker = ''; creator = ''
        version = ''; installed = ''
        kind = 'other'; detail = ''
        icaos = @(); aircraftTypes = @()
        certain = $true; fixed = $false; note = ''
    }
}

# -----------------------------------------------------------------------------
#  Read-LhvMsfsAddon
#  Looks at ONE MSFS add-on folder and says what it is.
#
#  Steps, in this order:
#    1. manifest.json  -> type, title, maker, creator
#    2. aircraft.cfg   -> aircraft type, or "this is a livery"
#    3. *.bgl          -> airport codes inside the scenery
#    4. the name       -> tree fix, library, traffic ... (only if 2 and 3 found nothing)
#
#  Input : full folder path, simulator name, "community", "marketplace" or
#          "library".
#  Output: one entry (see New-LhvEntry), or $null if the folder is not an
#          add-on or belongs to the simulator itself.
# -----------------------------------------------------------------------------
function Read-LhvMsfsAddon([string]$folder, [string]$sim, [string]$source) {
    $name     = Split-Path $folder -Leaf
    $manifest = Read-LhvManifest $folder
    if (-not $manifest) { return $null }
    if (Test-LhvBuiltIn $name $manifest.creator) { return $null }

    $e = New-LhvEntry $sim $source $name
    $e.type = $manifest.type; $e.title = $manifest.title
    $e.maker = $manifest.maker; $e.creator = $manifest.creator
    $e.version = $manifest.version
    $e.installed = Get-LhvInstallDate $folder

    # What the name says. Used to tell a real aircraft or airport from
    # traffic models, libraries and parts that carry the same kind of files.
    $named = Get-LhvKindFromName "$name $($manifest.title)"
    $isPart = ($named.kind -eq 'part')
    if ($isPart) { $named = @{ kind = 'other'; detail = $named.detail } }

    # --- 2. Aircraft or livery? ------------------------------------------------
    $cfgFiles = @(Get-LhvAddonFiles $folder '(?i)(^|[\\/])aircraft\.cfg$')
    if ($cfgFiles.Count -gt 0) {
        $types = New-Object System.Collections.Generic.List[string]
        $liveries = 0
        foreach ($cfg in $cfgFiles) {
            $c = Read-LhvAircraftCfg $cfg
            if ($c.isLivery) { $liveries++ }
            elseif ($c.icaoType -and -not $types.Contains($c.icaoType)) { $types.Add($c.icaoType) }
        }
        if ($liveries -gt 0 -and $types.Count -eq 0) {
            $e.kind = 'livery'; $e.detail = 'Livery'
            return $e
        }
        if ($types.Count -gt 0) {
            if ($named.kind -ne 'other' -or $isPart) {
                # Traffic models, jetway helpers, cabin packs ... have aircraft
                # files too, but you cannot fly them.
                $e.kind = $named.kind; $e.detail = $named.detail
            } elseif ($types.Count -gt $script:ManyTypes) {
                $e.kind = 'traffic'; $e.detail = 'AI traffic or model matching'
            } else {
                $e.kind = 'aircraft'; $e.aircraftTypes = @($types | Sort-Object)
            }
            return $e
        }
        if ($isPart -or ($named.kind -ne 'other')) {
            $e.kind = $named.kind; $e.detail = $named.detail
            return $e
        }
        if ($manifest.type -eq 'AIRCRAFT' -and $liveries -eq 0) {
            # An aircraft whose files do not say which type it is.
            $e.kind = 'aircraft'; $e.certain = $false
            $e.note = 'The aircraft files do not name a type. Which type is it?'
            return $e
        }
    }
    if ($manifest.type -eq 'LIVERY') { $e.kind = 'livery'; $e.detail = 'Livery'; return $e }
    if ($manifest.type -eq 'AIRCRAFT') {
        # No aircraft.cfg at all. In MSFS 2024 a livery has a "livery.cfg" instead;
        # everything else here is a part of an aircraft (cabin, textures, sounds).
        if (@(Get-LhvAddonFiles $folder '(?i)(^|[\\/])livery\.cfg$').Count -gt 0) {
            $e.kind = 'livery'; $e.detail = 'Livery'
        } else {
            $e.kind = 'other'; $e.detail = 'Part of an aircraft (cabin, textures, sounds)'
        }
        return $e
    }

    # --- 3. Airports inside the scenery files -----------------------------------
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($bgl in @(Get-LhvAddonFiles $folder '(?i)\.bgl$')) {
        foreach ($code in (Read-LhvBglAirports $bgl)) {
            if (-not $all.Contains($code)) { $all.Add($code) }
        }
    }
    if ($all.Count -gt 0) {
        # Navigation data and traffic packages also contain airport records
        # (thousands of them). They are not airport sceneries.
        if ($named.kind -eq 'navdata' -or $named.kind -eq 'traffic') {
            $e.kind = $named.kind; $e.detail = $named.detail
            return $e
        }
        $e.kind = 'airport'; $e.icaos = @($all | Sort-Object)
        if ($all.Count -gt $script:PackSize) {
            $e.detail  = "Pack with $($all.Count) airports"
            $e.certain = $false
            $e.note    = 'Contains many airports. A pack, a region or a data update?'
        } elseif ($named.kind -eq 'mod' -or $named.kind -eq 'library') {
            # e.g. "eddf-jetway-fix": touches an airport but is not the airport.
            $e.detail  = $named.detail
            $e.certain = $false
            $e.note    = "Looks like a mod for $($e.icaos -join ', '), not the airport itself."
        } elseif ((Get-LhvFileCount $folder) -le $script:TinyAddonFiles) {
            # A real airport scenery has many files (models, textures). A handful
            # of files that touch an airport are usually a fix for it.
            $e.detail  = 'Very small add-on'
            $e.certain = $false
            $e.note    = "Only a few files. A fix for $($e.icaos -join ', ') rather than the airport itself?"
        }
        return $e
    }

    # --- 4. No aircraft, no airport: the name decides ---------------------------
    $e.kind = $named.kind; $e.detail = $named.detail
    if ($manifest.type -eq 'SCENERY' -and $named.kind -eq 'other') {
        $e.detail = 'Scenery without an airport inside'
        # Only ask when the name itself says "airport": then the code is missing
        # from the files, and you can enter it with Quick fix.
        if ("$name $($manifest.title)" -match '(?i)airport|heliport|airfield|flugplatz|aerodrome') {
            $e.certain = $false
            $e.note    = 'Named like an airport, but no airport was found inside. Which airport is it?'
        }
    }
    return $e
}

# =============================================================================
#  PART 4 - X-PLANE
# =============================================================================

# -----------------------------------------------------------------------------
#  Read-LhvXplaneScenery
#  X-Plane sceneries list their airports in "Earth nav data\apt.dat".
#  An airport starts with a line like:   1 364 0 0 EDDF Frankfurt Main
#  (row codes 1, 16, 17 = land airport, seaplane base, heliport).
#  We read only those lines.
# -----------------------------------------------------------------------------
function Read-LhvXplaneScenery([string]$folder, [string]$sim) {
    $name = Split-Path $folder -Leaf
    $e    = New-LhvEntry $sim 'custom-scenery' $name
    $e.type = 'SCENERY'
    $codes = New-Object System.Collections.Generic.List[string]
    $apt   = Join-Path $folder 'Earth nav data\apt.dat'
    if (Test-Path -LiteralPath $apt) {
        try {
            foreach ($line in [System.IO.File]::ReadLines($apt)) {
                if ($line -match '^\s*(1|16|17)\s+-?\d+\s+\d+\s+\d+\s+([A-Za-z0-9]{3,7})\b') {
                    $code = $matches[2].ToUpper()
                    if (-not $codes.Contains($code)) { $codes.Add($code) }
                    if ($codes.Count -ge $script:MaxAirportsPerFile) { break }
                }
            }
        } catch { }
    }
    $named = Get-LhvKindFromName $name
    if ($codes.Count -gt 0 -and $named.kind -ne 'navdata') {
        $e.kind = 'airport'; $e.icaos = @($codes | Sort-Object)
        if ($codes.Count -gt $script:PackSize) {
            $e.detail = "Pack with $($codes.Count) airports"; $e.certain = $false
            $e.note   = 'Contains many airports. A pack, a region or a data update?'
        }
    } else {
        # No apt.dat: an overlay, a library or a mesh. Not an airport.
        $e.kind = $named.kind; $e.detail = $named.detail
        if ($named.kind -eq 'other') { $e.detail = 'No airport inside' }
    }
    return $e
}

# -----------------------------------------------------------------------------
#  Read-LhvXplaneAircraft
#  An X-Plane aircraft has an ".acf" text file with one line that names the
#  type:   P acf/_ICAO A320
#  We read the first lines of the file until that line is found.
# -----------------------------------------------------------------------------
function Read-LhvXplaneAircraft([string]$folder, [string]$sim) {
    $name = Split-Path $folder -Leaf
    $e    = New-LhvEntry $sim 'aircraft-folder' $name
    $e.type = 'AIRCRAFT'; $e.kind = 'aircraft'
    $types = New-Object System.Collections.Generic.List[string]
    foreach ($acf in @(Get-LhvAddonFiles $folder '(?i)\.acf$')) {
        try {
            $read = 0
            foreach ($line in [System.IO.File]::ReadLines($acf)) {
                $read++
                if ($line -match '^P acf/_ICAO\s+([A-Za-z0-9]{2,4})\s*$') {
                    $t = $matches[1].ToUpper()
                    if (-not $types.Contains($t)) { $types.Add($t) }
                    break
                }
                if ($read -gt 20000) { break }
            }
        } catch { }
    }
    if ($types.Count -gt 0) { $e.aircraftTypes = @($types | Sort-Object) }
    else { $e.certain = $false; $e.note = 'The aircraft files do not name a type.' }
    return $e
}

# =============================================================================
#  PART 5 - FINDING THE SIMULATORS AND SCANNING THEM
# =============================================================================

# -----------------------------------------------------------------------------
#  Find-LhvMsfsPackages
#  MSFS writes its add-on location into UserCfg.opt, in one line:
#      InstalledPackagesPath "G:\Microsoft Flight Simulator"
#  We read ONLY that line.
#  Input : the places where UserCfg.opt can be (Steam or Microsoft Store).
#  Output: the add-on root folder, or $null if this MSFS is not installed.
# -----------------------------------------------------------------------------
function Find-LhvMsfsPackages([string[]]$settingsFiles) {
    foreach ($cfg in $settingsFiles) {
        if (Test-Path -LiteralPath $cfg) {
            $line = Get-Content -LiteralPath $cfg | Where-Object { $_ -like 'InstalledPackagesPath*' } | Select-Object -First 1
            if ($line) {
                $path = ($line -split '"')[1]            # the text between the quote marks
                if ($path -and (Test-Path -LiteralPath $path)) { return $path }
            }
        }
    }
    return $null
}

# -----------------------------------------------------------------------------
#  Get-LhvSimulators
#  Finds the simulators on this PC and the folders where their add-ons live.
#  Nothing is scanned yet; this only answers "what is installed, and where".
#
#  Output: a list of
#    @{ id; name; places = @( @{ path; source; kind } ) }
#  id is msfs2020, msfs2024, xplane11 or xplane12.
#  kind says how a place is read: "msfs", "xp-aircraft" or "xp-scenery".
# -----------------------------------------------------------------------------
function Get-LhvSimulators {
    $roaming = $env:APPDATA
    $local   = $env:LOCALAPPDATA
    $sims    = @()

    $root = Find-LhvMsfsPackages @(
        "$roaming\Microsoft Flight Simulator\UserCfg.opt",                                   # Steam
        "$local\Packages\Microsoft.FlightSimulator_8wekyb3d8bbwe\LocalCache\UserCfg.opt")    # Microsoft Store
    if ($root) {
        $sims += @{ id = 'msfs2020'; name = 'MSFS 2020'; places = @(
            @{ path = "$root\Community";         source = 'community';   kind = 'msfs' },
            @{ path = "$root\Official\Steam";    source = 'marketplace'; kind = 'msfs' },
            @{ path = "$root\Official\OneStore"; source = 'marketplace'; kind = 'msfs' }) }
    }

    $root = Find-LhvMsfsPackages @(
        "$roaming\Microsoft Flight Simulator 2024\UserCfg.opt",                              # Steam
        "$local\Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt")          # Microsoft Store
    if ($root) {
        $sims += @{ id = 'msfs2024'; name = 'MSFS 2024'; places = @(
            @{ path = "$root\Community";             source = 'community';   kind = 'msfs' },
            @{ path = "$root\Community2024";         source = 'marketplace'; kind = 'msfs' },
            @{ path = "$root\Official2024\Steam";    source = 'marketplace'; kind = 'msfs' },
            @{ path = "$root\Official2024\OneStore"; source = 'marketplace'; kind = 'msfs' }) }
    }

    foreach ($v in @('11', '12')) {
        # X-Plane writes its install folder into the first line of this file.
        $installFile = "$local\x-plane_install_$v.txt"
        if (-not (Test-Path -LiteralPath $installFile)) { continue }
        $xp = "$(Get-Content -LiteralPath $installFile | Select-Object -First 1)".Trim().TrimEnd('/', '\')
        if (-not $xp -or -not (Test-Path -LiteralPath $xp)) { continue }
        $sims += @{ id = "xplane$v"; name = "X-Plane $v"; places = @(
            @{ path = "$xp\Aircraft";       source = 'aircraft-folder'; kind = 'xp-aircraft' },
            @{ path = "$xp\Custom Scenery"; source = 'custom-scenery';  kind = 'xp-scenery' }) }
    }

    # Keep only the places that really exist on this PC.
    foreach ($sim in $sims) {
        $sim.places = @($sim.places | Where-Object { Test-Path -LiteralPath $_.path })
    }
    return @($sims | Where-Object { $_.places.Count -gt 0 })
}

# -----------------------------------------------------------------------------
#  Get-LhvLibraries
#  Finds the add-on LIBRARIES: folders outside the simulator where you keep
#  add-ons. An add-on manager puts only the add-ons that are switched ON into
#  Community, as links; the ones switched OFF stay in its library and would
#  be missed. They are still installed on your PC, so they are read too.
#
#  Two ways a folder becomes a library:
#    1. Linked add-ons in a Community folder point into it (see
#       Group-LhvLinkTargets for which folder exactly).
#    2. You added it yourself ("Add folder" in the window, kept in
#       %APPDATA%\LHV-Scan\libraries.json). It belongs to MSFS 2024 if that
#       is on this PC, else to MSFS 2020.
#  Each library is listed once. It belongs to the simulator whose Community
#  folder linked into it first.
#
#  A simulator folder is NEVER a library: no place of any simulator found on
#  this PC (ticked or not, compared by its real path, see
#  Resolve-LhvRealPath), and no folder named Community, Community2024 or
#  Official... Many pilots link their MSFS 2020 add-ons into MSFS 2024; those
#  add-ons belong to MSFS 2020 and must not show up as MSFS 2024 installs.
#  Simulator folders INSIDE a library are skipped when it is searched.
#
#  Input : -Simulators     the simulators to scan (the ticked ones)
#          -AllSimulators  every simulator found on this PC (default: the
#                          same list). Their folders are never libraries, and
#                          they decide which sim a folder you added belongs to.
#          -UserFolders    the folders you added (default: libraries.json)
#  Output: a list of @{ path; sim; fromUser; exclude; read; addons; linked;
#          stopped }. read, addons, linked and stopped are filled in by
#          Invoke-LhvScan. exclude are the simulator folders inside it.
# -----------------------------------------------------------------------------
function Get-LhvLibraries {
    param($Simulators, $AllSimulators = $null, [string[]]$UserFolders = (Read-LhvLibraryFolders))
    if ($null -eq $AllSimulators) { $AllSimulators = $Simulators }

    # The real places of every simulator on this PC, ticked or not.
    $known = New-Object System.Collections.Generic.List[string]
    foreach ($sim in (@($AllSimulators) + @($Simulators))) {
        foreach ($place in @($sim.places)) {
            if (-not $place) { continue }
            foreach ($key in @((ConvertTo-LhvFolderKey $place.path), (Resolve-LhvRealPath $place.path))) {
                if ($key -and -not ($known -contains $key)) { $known.Add($key) }   # -contains ignores case
            }
        }
    }
    $knownList = $known.ToArray()
    $libraries = New-Object System.Collections.Generic.List[object]
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $newLibrary = {
        param($path, $sim, $fromUser)
        $inside = @($knownList | Where-Object { Test-LhvInsideFolder $_ $path })
        return @{ path = $path; sim = $sim; fromUser = $fromUser; exclude = $inside
                  read = $false; addons = 0; linked = 0; stopped = $false }
    }

    # 1. Libraries behind the links in Community.
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($sim in @($Simulators)) {
        foreach ($place in @($sim.places)) {
            if ($place.kind -ne 'msfs' -or $place.source -ne 'community') { continue }
            try { $dirs = [System.IO.Directory]::GetDirectories($place.path) } catch { continue }
            foreach ($dir in $dirs) {
                if (-not (Get-LhvLinkTarget $dir)) { continue }
                $real = Resolve-LhvRealPath $dir
                if ($real) { $targets.Add(@{ target = $real; sim = $sim.name }) }
            }
        }
    }
    foreach ($group in @(Group-LhvLinkTargets $targets.ToArray() $knownList)) {
        if (-not (Test-Path -LiteralPath $group.path -PathType Container)) { continue }
        if ($keys.Add($group.path)) { $libraries.Add((& $newLibrary $group.path $group.sim $false)) }
    }

    # 2. The folders you added yourself. Which sim they belong to is decided
    #    by what is on this PC, not by what is ticked.
    $msfs = @(@($AllSimulators) | Where-Object { $_.id -eq 'msfs2024' }) + @(@($AllSimulators) | Where-Object { $_.id -eq 'msfs2020' })
    $userSim = $script:LhvNoSimName
    if ($msfs.Count -gt 0) { $userSim = $msfs[0].name }
    foreach ($folder in @($UserFolders)) {
        if (-not $folder) { continue }
        try {
            if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
            $real = Resolve-LhvRealPath $folder
            if (-not $real -or (Test-LhvSimFolder $real $knownList)) { continue }   # read as a simulator folder anyway
            if ($keys.Add($real)) { $libraries.Add((& $newLibrary $real $userSim $true)) }
        } catch { }
    }
    return $libraries.ToArray()
}

# -----------------------------------------------------------------------------
#  Group-LhvLinkTargets
#  Decides WHICH folders are libraries, from the places the links point to.
#
#  An add-on manager usually sorts its add-ons into a tree, for example
#      D:\Addons\Airports\EDDF\<add-on>      (switched on: linked)
#      D:\Addons\Aircraft\A320\<add-on>      (switched on: linked)
#      D:\Addons\Aircraft\B738\<add-on>      (switched off: no link)
#  The library is the deepest folder that ALL link targets on the same drive
#  have in common - here D:\Addons - so the switched-off add-ons in the
#  other category folders are found too, and the window shows one line
#  instead of one per category. The common folder must be at least one
#  level below the drive root (D:\Addons, never D:\ itself).
#  Targets that have nothing deeper in common (D:\Addons\... and D:\Games\...)
#  each form a library of their own, the folder that holds them.
#  A common folder that CONTAINS a simulator folder (for example
#  G:\MSFS, which holds G:\MSFS\Community) is not taken either: the targets
#  are split into the next level below it.
#  Targets inside a simulator folder are left out (see Test-LhvSimFolder).
#
#  Personal and system folders are never searched as a library: a folder that
#  IS or lies ABOVE one of them (see Get-LhvProtectedFolders - your user
#  folder, C:\Users, Documents, Downloads, Desktop, Program Files, ProgramData,
#  Windows, a drive root) is rejected. Links into Downloads\A\... and
#  Documents\B\... would otherwise make your whole user folder a library.
#  Then each target's own folder is taken instead (Downloads\A, Documents\B),
#  and if that one is a personal or system folder too, there is no library
#  for it ("Add folder" in the window still works). Folders BELOW such a
#  folder are fine: C:\Program Files (x86)\Addon Manager\MSFS is a library.
#
#  It only compares paths: it never opens a folder.
#
#  Input : $items      a list of @{ target; sim }: real paths of the link targets
#          $known      real paths of all simulator folders
#          $protected  personal and system folders (default: this PC's)
#  Output: a list of @{ path; sim }, one per library. sim is the sim of the
#          first link that pointed into it.
# -----------------------------------------------------------------------------
function Group-LhvLinkTargets($items, [string[]]$known, [string[]]$protected = (Get-LhvProtectedFolders)) {
    # Is $path one of the protected folders, or above one?
    $tooHigh = {
        param($path)
        foreach ($p in @($protected)) { if ($p -and (Test-LhvInsideFolder $p $path)) { return $true } }
        return $false
    }
    # Each target becomes the folder that holds it ("holder").
    $byRoot = [ordered]@{}
    foreach ($item in @($items)) {
        if (-not $item) { continue }
        $split = Split-LhvFolder $item.target
        $parts = @($split.parts)
        if ($parts.Count -lt 2) { continue }                    # an add-on right on a drive: no library
        $holder = @{ root = $split.root; parts = $parts[0..($parts.Count - 2)]; sim = $item.sim }
        if (Test-LhvSimFolder (Join-LhvFolder $holder.root $holder.parts) $known) { continue }
        $rootKey = $split.root.ToLowerInvariant()
        if (-not $byRoot.Contains($rootKey)) { $byRoot[$rootKey] = New-Object System.Collections.Generic.List[object] }
        $byRoot[$rootKey].Add($holder)
    }

    $result = New-Object System.Collections.Generic.List[object]
    $taken  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $queue  = New-Object System.Collections.Generic.Queue[object]
    foreach ($key in $byRoot.Keys) { $queue.Enqueue($byRoot[$key].ToArray()) }
    while ($queue.Count -gt 0) {
        $group = $queue.Dequeue()
        # The folder names all holders in this group share, from the root down.
        $common = New-Object System.Collections.Generic.List[string]
        $first = @($group[0].parts)
        for ($i = 0; $i -lt $first.Count; $i++) {
            $same = $true
            foreach ($h in $group) {
                $p = @($h.parts)
                if ($p.Count -le $i -or -not $p[$i].Equals($first[$i], [System.StringComparison]::OrdinalIgnoreCase)) { $same = $false; break }
            }
            if (-not $same) { break }
            $common.Add($first[$i])
        }
        $path = Join-LhvFolder $group[0].root $common.ToArray()
        $holdsSim = @($known | Where-Object { $_ -and (Test-LhvInsideFolder $_ $path) }).Count -gt 0
        if (& $tooHigh $path) {
            # A personal or system folder (or above one): each target's own
            # folder instead, unless that one is too high as well.
            foreach ($h in $group) {
                $own = Join-LhvFolder $h.root $h.parts
                if (& $tooHigh $own) { continue }
                if (@($known | Where-Object { $_ -and (Test-LhvInsideFolder $_ $own) }).Count -gt 0) { continue }
                if ($taken.Add($own)) { $result.Add(@{ path = $own; sim = $h.sim }) }
            }
            continue
        }
        if ($common.Count -ge 1 -and -not $holdsSim) {
            if ($taken.Add($path)) { $result.Add(@{ path = $path; sim = $group[0].sim }) }
            continue
        }
        # Too high (a drive root, or a folder that holds a simulator folder):
        # split by the next folder name. Holders that are this folder itself
        # cannot go deeper and are left out.
        $depth = $common.Count
        $sub = [ordered]@{}
        foreach ($h in $group) {
            $p = @($h.parts)
            if ($p.Count -le $depth) { continue }
            $name = $p[$depth].ToLowerInvariant()
            if (-not $sub.Contains($name)) { $sub[$name] = New-Object System.Collections.Generic.List[object] }
            $sub[$name].Add($h)
        }
        foreach ($name in $sub.Keys) { $queue.Enqueue($sub[$name].ToArray()) }
    }
    return $result.ToArray()
}

# -----------------------------------------------------------------------------
#  Find-LhvLibraryAddons
#  Lists the add-on folders inside a library. An add-on folder is one that
#  contains manifest.json. Libraries are often sorted into sub-folders
#  ("Airports\Germany\..."), so the search goes up to $script:LibraryDepth
#  levels deep. It does not look inside an add-on folder: an add-on never
#  contains another add-on.
#
#  Skipped on the way: simulator folders (they are read as such), and links
#  that lead back to a folder already seen (a loop would count add-ons twice).
#  At most $script:MaxLibraryFolders folders are looked at; then the search
#  stops and says so (a library on a whole drive would otherwise take ages).
#
#  Input : the library folder, the simulator folders inside it (exclude),
#          and optionally the progress block of Invoke-LhvScan with the sim
#          name. Progress is reported as (0, 0, simName, libraryPath) - total
#          0 means "searching a library" - every 200 folders.
#  Output: @{ addons = full paths of the add-on folders; stopped = $true if
#          the folder limit was reached; visited = folders looked at }
# -----------------------------------------------------------------------------
function Find-LhvLibraryAddons([string]$library, $exclude = @(), [scriptblock]$OnProgress = $null, [string]$sim = '') {
    $found = New-Object System.Collections.Generic.List[string]
    $skip  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in @($exclude)) { if ($e) { [void]$skip.Add("$e") } }
    $seen  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    try { [void]$seen.Add((ConvertTo-LhvFolderKey $library)) } catch { }
    $visited = 0; $stopped = $false
    if ($OnProgress) { & $OnProgress 0 0 $sim $library }
    $level = @($library)
    :walk for ($depth = 1; $depth -le $script:LibraryDepth -and $level.Count -gt 0; $depth++) {
        $next = New-Object System.Collections.Generic.List[string]
        foreach ($parent in $level) {
            try { $dirs = [System.IO.Directory]::GetDirectories($parent) } catch { continue }
            foreach ($dir in $dirs) {
                if ($visited -ge $script:MaxLibraryFolders) { $stopped = $true; break walk }
                $visited++
                if ($OnProgress -and ($visited % 200) -eq 0) { & $OnProgress 0 0 $sim $library }
                if ((Split-Path $dir -Leaf) -match $script:SimFolderNames) { continue }
                $key = Get-LhvLinkTarget $dir
                if (-not $key) { $key = $dir }
                if ($skip.Contains($dir) -or $skip.Contains($key)) { continue }
                if (-not $seen.Add($key)) { continue }
                if ([System.IO.File]::Exists((Join-Path $dir 'manifest.json'))) { $found.Add($dir) }
                else { $next.Add($dir) }
            }
        }
        $level = $next.ToArray()
    }
    return @{ addons = $found.ToArray(); stopped = $stopped; visited = $visited }
}

# -----------------------------------------------------------------------------
#  Clear-LhvMovingDay
#  When you move your add-ons (to a new drive, or from MSFS 2020 to 2024),
#  every folder gets a new creation date: the day of the move. That day is
#  not an install date. So: if more than $script:MovingDayLimit add-ons share
#  one date, that date is removed from all of them.
#
#  Input : the entries of the whole scan. They are changed in place.
# -----------------------------------------------------------------------------
function Clear-LhvMovingDay($entries) {
    # "foreach ($e in $entries)", not "@($entries)": Windows PowerShell 5.1
    # fails on @() around a list of entries ("argument types do not match").
    $perDay = @{}
    foreach ($e in $entries) {
        if ($e.installed) { $perDay[$e.installed] = 1 + [int]$perDay[$e.installed] }
    }
    foreach ($e in $entries) {
        if ($e.installed -and $perDay[$e.installed] -gt $script:MovingDayLimit) { $e.installed = '' }
    }
}

# -----------------------------------------------------------------------------
#  Invoke-LhvScan
#  Walks through the given simulators and libraries and reads every add-on
#  folder.
#
#  An add-on in a library that a Community link points to - or whose folder
#  NAME is also in a Community folder - is the same add-on, switched on
#  through a link. It was read from Community already, so it is only counted
#  as "linked", not read twice. (The path check catches links that were
#  renamed, the name check copies that are not links.)
#
#  Input : -Simulators  the list from Get-LhvSimulators (or a part of it)
#          -Libraries   optional: the list from Get-LhvLibraries. Its
#                       read, addons, linked and stopped are filled in here.
#          -OnProgress  optional: a script block called for every folder, with
#                       (done, total, simName, folderName). The window uses
#                       it to show what is being read right now. While a
#                       library is searched it is called with total 0 and
#                       the library as folderName (see Find-LhvLibraryAddons).
#  Output: the list of entries (see New-LhvEntry).
# -----------------------------------------------------------------------------
function Invoke-LhvScan {
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] $Simulators, $Libraries = @(), [scriptblock] $OnProgress)

    # First collect all folders, so the progress bar knows the total.
    $jobs = New-Object System.Collections.Generic.List[object]
    $inCommunity = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $linkedTo    = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($sim in @($Simulators)) {
        foreach ($place in @($sim.places)) {
            try {
                foreach ($dir in [System.IO.Directory]::GetDirectories($place.path)) {
                    $jobs.Add(@{ sim = $sim.name; place = $place; dir = $dir })
                    if ($place.kind -ne 'msfs' -or $place.source -ne 'community') { continue }
                    [void]$inCommunity.Add((Split-Path $dir -Leaf))
                    if (@($Libraries).Count -gt 0 -and (Get-LhvLinkTarget $dir)) {
                        $real = Resolve-LhvRealPath $dir
                        if ($real) { [void]$linkedTo.Add($real) }
                    }
                }
            } catch { }
        }
    }

    # Then the add-ons in the libraries.
    $libraryPlace = @{ source = 'library'; kind = 'msfs' }
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($library in @($Libraries)) {
        if (-not $library) { continue }
        $library.addons = 0; $library.linked = 0
        $search = Find-LhvLibraryAddons $library.path $library.exclude $OnProgress $library.sim
        $library.stopped = [bool]$search.stopped
        foreach ($dir in @($search.addons)) {
            if (-not $seenPaths.Add($dir)) { continue }                        # found through another library already
            $library.addons++
            $name = Split-Path $dir -Leaf
            $key  = ConvertTo-LhvFolderKey $dir
            if ($linkedTo.Contains($key) -or $inCommunity.Contains($name)) {
                $library.linked++; continue                                    # switched on: read from Community
            }
            if (-not $seenNames.Add($name)) { continue }                       # the same add-on in two libraries: read once
            $jobs.Add(@{ sim = $library.sim; place = $libraryPlace; dir = $dir })
        }
        $library.read = $true
    }

    $entries = New-Object System.Collections.Generic.List[object]
    $done = 0
    foreach ($job in $jobs) {
        $done++
        if ($OnProgress) { & $OnProgress $done $jobs.Count $job.sim (Split-Path $job.dir -Leaf) }
        $entry = $null
        switch ($job.place.kind) {
            'msfs'        { $entry = Read-LhvMsfsAddon      $job.dir $job.sim $job.place.source }
            'xp-aircraft' { $entry = Read-LhvXplaneAircraft $job.dir $job.sim }
            'xp-scenery'  { $entry = Read-LhvXplaneScenery  $job.dir $job.sim }
        }
        if ($entry) { $entries.Add($entry) }
    }
    Clear-LhvMovingDay $entries
    return $entries.ToArray()
}

# =============================================================================
#  PART 6 - YOUR OWN CORRECTIONS ("QUICK FIX") AND THE RESULT FILE
# =============================================================================

# -----------------------------------------------------------------------------
#  Get-LhvFixFile
#  Where your corrections are remembered, so you only make them once:
#      C:\Users\<you>\AppData\Roaming\LHV-Scan\fixes.json
#  This is the only file the tool keeps on your PC besides the result file.
# -----------------------------------------------------------------------------
function Get-LhvFixFile {
    return (Join-Path $env:APPDATA 'LHV-Scan\fixes.json')
}

# -----------------------------------------------------------------------------
#  Read-LhvFixes
#  Loads your earlier corrections.
#  Output: a table  "sim|folder"  ->  @{ kind; icaos; aircraftTypes }
# -----------------------------------------------------------------------------
function Read-LhvFixes([string]$file = (Get-LhvFixFile)) {
    $fixes = @{}
    if (Test-Path -LiteralPath $file) {
        try {
            $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($item in @($data.fixes)) {
                $fixes["$($item.sim)|$($item.folder)"] = @{
                    kind          = "$($item.kind)"
                    icaos         = @($item.icaos | ForEach-Object { "$_" })
                    aircraftTypes = @($item.aircraftTypes | ForEach-Object { "$_" })
                }
            }
        } catch { }
    }
    return $fixes
}

# -----------------------------------------------------------------------------
#  Save-LhvFixes
#  Writes your corrections to the file from Get-LhvFixFile.
# -----------------------------------------------------------------------------
function Save-LhvFixes($fixes, [string]$file = (Get-LhvFixFile)) {
    $list = @()
    foreach ($key in ($fixes.Keys | Sort-Object)) {
        $sim, $folder = $key -split '\|', 2
        $list += [ordered]@{ sim = $sim; folder = $folder; kind = $fixes[$key].kind
                             icaos = @($fixes[$key].icaos); aircraftTypes = @($fixes[$key].aircraftTypes) }
    }
    $dir = Split-Path $file -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $json = [ordered]@{ format = 'lhv-scan-fixes/1'; fixes = $list } | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# -----------------------------------------------------------------------------
#  Get-LhvLibraryFile
#  Where the add-on folders you added yourself are remembered:
#      C:\Users\<you>\AppData\Roaming\LHV-Scan\libraries.json
#  It is a plain list of folder paths. It stays on your PC and is never sent.
# -----------------------------------------------------------------------------
function Get-LhvLibraryFile {
    return (Join-Path $env:APPDATA 'LHV-Scan\libraries.json')
}

# -----------------------------------------------------------------------------
#  Read-LhvLibraryFolders
#  Loads the folders you added. Anything that is not a full path ("D:\..."
#  or "\\server\share\...") is ignored. "D:\A" and "D:\a\" count as one.
#  Output: a list of folder paths (each once).
# -----------------------------------------------------------------------------
function Read-LhvLibraryFolders([string]$file = (Get-LhvLibraryFile)) {
    $folders = New-Object System.Collections.Generic.List[string]
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $file) {
        try {
            $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($item in @($data)) {
                if ($item -isnot [string]) { continue }
                $path = $item.Trim()
                if ($path -notmatch '^([A-Za-z]:\\|\\\\[^\\])') { continue }
                try { $key = ConvertTo-LhvFolderKey $path } catch { continue }
                if ($keys.Add($key)) { $folders.Add($path) }
            }
        } catch { }
    }
    return $folders.ToArray()
}

# -----------------------------------------------------------------------------
#  Save-LhvLibraryFolders
#  Writes the folders you added to the file from Get-LhvLibraryFile.
# -----------------------------------------------------------------------------
function Save-LhvLibraryFolders($folders, [string]$file = (Get-LhvLibraryFile)) {
    $list = @(@($folders) | Where-Object { $_ } | ForEach-Object { "$_" })
    $dir = Split-Path $file -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    # -InputObject keeps a list of one folder a list (piping would unwrap it).
    $json = ConvertTo-Json -InputObject $list
    [System.IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# -----------------------------------------------------------------------------
#  Set-LhvFix
#  Applies ONE correction to an entry, e.g. "this is the airport EDDK".
#  Input : the entry, the kind you chose, and the codes you typed.
#  Output: the same entry, now marked certain and fixed.
# -----------------------------------------------------------------------------
function Set-LhvFix($entry, [string]$kind, [string[]]$icaos, [string[]]$aircraftTypes) {
    # Only the three choices of the window are accepted; anything else
    # (a damaged fixes.json, for example) counts as "not an airport or aircraft".
    if ($kind -ne 'airport' -and $kind -ne 'aircraft') { $kind = 'mod' }
    $entry.kind          = $kind
    $entry.icaos         = @($icaos | ForEach-Object { "$_".Trim().ToUpper() } | Where-Object { $_ -match '^[A-Z0-9]{3,8}$' })
    $entry.aircraftTypes = @($aircraftTypes | ForEach-Object { "$_".Trim().ToUpper() } | Where-Object { $_ -match '^[A-Z0-9]{2,4}$' })
    $entry.certain       = $true
    $entry.fixed         = $true
    $entry.note          = ''
    if ($kind -ne 'airport' -and $kind -ne 'aircraft') { $entry.detail = 'Set by you' }
    return $entry
}

# -----------------------------------------------------------------------------
#  Use-LhvFixes
#  Applies your remembered corrections to a fresh scan result.
# -----------------------------------------------------------------------------
function Use-LhvFixes($entries, $fixes) {
    foreach ($entry in $entries) {
        $fix = $fixes["$($entry.sim)|$($entry.folder)"]
        if ($fix) { [void](Set-LhvFix $entry $fix.kind $fix.icaos $fix.aircraftTypes) }
    }
    return $entries
}

# -----------------------------------------------------------------------------
#  ConvertTo-LhvAddonFile
#  Builds the text of the result (the file lhv-addons.json, and exactly what
#  "Send to My sim" sends).
#
#  Only what LH Virtual needs goes in:
#    - the airports and aircraft that are clear (read from the add-on's own
#      files, or fixed by you), each with: simulator name, folder NAME, title,
#      maker, airport codes or aircraft types, and - only when known - the
#      install date ("installed") and the add-on's version ("version")
#    - for everything else just a COUNT per kind ("103 liveries, 21 mods")
#  Add-ons from a library are listed like the ones in Community: installed
#  is installed, switched on or not.
#
#  It contains no folder paths, no user name and nothing about your PC apart
#  from the install date and version of the listed add-ons.
#  Liveries, mods, libraries, tools and unclear add-ons are not listed by name.
#
#  Input : the entries.
#  Output: the text (JSON).
# -----------------------------------------------------------------------------
function ConvertTo-LhvAddonFile($entries) {
    $counted = @($entries | Where-Object { $_.certain -and ($_.kind -eq 'airport' -or $_.kind -eq 'aircraft') })
    $rest    = @($entries | Where-Object { -not ($_.certain -and ($_.kind -eq 'airport' -or $_.kind -eq 'aircraft')) })

    # How many add-ons of each other kind there are. Unclear ones count as "unclear".
    $notListed = [ordered]@{}
    foreach ($e in $rest) {
        $key = $e.kind; if (-not $e.certain) { $key = 'unclear' }
        if ($notListed.Contains($key)) { $notListed[$key]++ } else { $notListed[$key] = 1 }
    }

    $result = [ordered]@{
        format    = $script:LhvFileFormat
        tool      = "LHV Scan $($script:LhvScanVersion)"
        created   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        sims      = @($entries | ForEach-Object { $_.sim } | Sort-Object -Unique)
        count     = $counted.Count
        notListed = $notListed
        addons    = @($counted | ForEach-Object {
            $item = [ordered]@{
                sim = $_.sim; folder = $_.folder; title = $_.title; maker = $_.maker
                kind = $_.kind
                icaos = @($_.icaos); aircraftTypes = @($_.aircraftTypes)
                fixed = [bool]$_.fixed
            }
            # Optional fields: left out when not known, so older receivers
            # see exactly the format they know.
            if ("$($_.installed)") { $item['installed'] = "$($_.installed)" }
            if ("$($_.version)")   { $item['version']   = "$($_.version)" }
            $item
        })
    }
    return ($result | ConvertTo-Json -Depth 6)
}

# -----------------------------------------------------------------------------
#  Save-LhvAddonFile
#  Writes the result file as plain UTF-8 text. You can open it with Notepad.
# -----------------------------------------------------------------------------
function Save-LhvAddonFile($entries, [string]$path) {
    [System.IO.File]::WriteAllText($path, (ConvertTo-LhvAddonFile $entries), (New-Object System.Text.UTF8Encoding($false)))
}
