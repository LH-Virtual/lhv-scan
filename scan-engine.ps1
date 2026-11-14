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
#    manifest.json          type, title, maker, creator of an MSFS add-on
#    layout.json            the list of file NAMES inside an MSFS add-on
#    *.bgl                  only the airport codes stored in a scenery file
#    aircraft.cfg           three lines: aircraft type, title, "is a livery"
#    apt.dat                the airport codes of an X-Plane scenery
#    *.acf                  one line: the aircraft type of an X-Plane aircraft
#
#  Everything is plain text. Lines starting with # are explanations.
#  Works with the Windows PowerShell that is part of Windows 10 and 11.
# =============================================================================

# The version of this tool and of the file it writes.
$script:LhvScanVersion = '1.0.0'
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
#  Reads four fields from an MSFS add-on's manifest.json.
#  Input : the add-on folder.
#  Output: @{ type; title; maker; creator } or $null if there is no manifest
#          (then the folder is not an MSFS add-on).
# -----------------------------------------------------------------------------
function Read-LhvManifest([string]$folder) {
    $path = Join-Path $folder 'manifest.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $m = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return @{ type    = "$($m.content_type)".ToUpper()
                  title   = "$($m.title)"
                  maker   = "$($m.manufacturer)"
                  creator = "$($m.creator)" }
    } catch {
        # Broken manifest: we still know it is an add-on, just not which kind.
        return @{ type = 'UNKNOWN'; title = ''; maker = ''; creator = '' }
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
#  Input : add-on folder, a regular expression for the file name.
#  Output: full paths, at most $script:MaxFilesPerAddon of them.
# -----------------------------------------------------------------------------
function Get-LhvAddonFiles([string]$folder, [string]$namePattern) {
    $files  = New-Object System.Collections.Generic.List[string]
    $layout = Join-Path $folder 'layout.json'
    if (Test-Path -LiteralPath $layout) {
        try {
            $list = (Get-Content -LiteralPath $layout -Raw -Encoding UTF8 | ConvertFrom-Json).content
            foreach ($item in $list) {
                if ("$($item.path)" -match $namePattern) {
                    $full = Join-Path $folder ("$($item.path)" -replace '/', '\')
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
#    type, title, maker, creator   from manifest.json (MSFS)
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
#  Input : full folder path, simulator name, "community" or "marketplace".
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
#  Invoke-LhvScan
#  Walks through the given simulators and reads every add-on folder.
#
#  Input : -Simulators  the list from Get-LhvSimulators (or a part of it)
#          -OnProgress  optional: a script block called for every folder, with
#                       (done, total, simName, folderName). The window uses
#                       it to show what is being read right now.
#  Output: the list of entries (see New-LhvEntry).
# -----------------------------------------------------------------------------
function Invoke-LhvScan {
    param([Parameter(Mandatory = $true)] $Simulators, [scriptblock] $OnProgress)

    # First collect all folders, so the progress bar knows the total.
    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($sim in $Simulators) {
        foreach ($place in $sim.places) {
            try {
                foreach ($dir in [System.IO.Directory]::GetDirectories($place.path)) {
                    $jobs.Add(@{ sim = $sim.name; place = $place; dir = $dir })
                }
            } catch { }
        }
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
#  Set-LhvFix
#  Applies ONE correction to an entry, e.g. "this is the airport EDDK".
#  Input : the entry, the kind you chose, and the codes you typed.
#  Output: the same entry, now marked certain and fixed.
# -----------------------------------------------------------------------------
function Set-LhvFix($entry, [string]$kind, [string[]]$icaos, [string[]]$aircraftTypes) {
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
#      maker, airport codes or aircraft types
#    - for everything else just a COUNT per kind ("103 liveries, 21 mods")
#
#  It contains no folder paths, no user name and nothing about your PC.
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
            [ordered]@{
                sim = $_.sim; folder = $_.folder; title = $_.title; maker = $_.maker
                kind = $_.kind
                icaos = @($_.icaos); aircraftTypes = @($_.aircraftTypes)
                fixed = [bool]$_.fixed
            }
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
