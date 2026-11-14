# =============================================================================
#  LHV Scan - tests for the reading part
# =============================================================================
#
#  Run:   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Engine.ps1
#
#  The tests build a small made-up simulator folder in the Windows temp
#  folder (a few tiny add-ons, written byte by byte), let the engine read it
#  and compare the result with what must come out. The folder is deleted at
#  the end. No real simulator is needed and nothing outside the temp folder
#  is touched.
# =============================================================================
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scan-engine.ps1')

$script:Checks = 0
function Assert-Equal($actual, $expected, [string]$what) {
    $script:Checks++
    $a = ($actual | ConvertTo-Json -Compress -Depth 5); $e = ($expected | ConvertTo-Json -Compress -Depth 5)
    if ($a -ne $e) { throw "FAILED: $what`n   expected $e`n   got      $a" }
}

# ---- helpers that write test files ------------------------------------------

# The opposite of ConvertFrom-LhvIcaoCode: "EDDF" -> 900199.
function ConvertTo-TestIcaoNumber([string]$code) {
    $value = [int64]0
    foreach ($char in $code.ToCharArray()) {
        if ($char -ge '0' -and $char -le '9') { $digit = 2 + ([int]$char - 48) } else { $digit = 12 + ([int]$char - 65) }
        $value = $value * 38 + $digit
    }
    return $value
}

# Writes a scenery file with one airport section. $layout is "old" (4-byte
# code at 0x28) or "new" (8-byte code at 0x4C, as MSFS 2024 writes it).
function New-TestBgl([string]$path, [string[]]$codes, [string]$layout) {
    $recordSize = 0x60
    $stream = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($stream)
    $w.Write([uint32]0x19920201); $w.Write([uint32]0x38)          # magic, header size
    $w.Write((New-Object byte[] 12)); $w.Write([uint32]1)          # ... one section
    $w.Write((New-Object byte[] 32))                               # rest of the header (0x38 bytes)
    $subOffset  = 0x38 + 20
    $dataOffset = $subOffset + 16
    $w.Write([uint32]0x03); $w.Write([uint32]1); $w.Write([uint32]1); $w.Write([uint32]$subOffset); $w.Write([uint32]16)
    $w.Write([uint32]0); $w.Write([uint32]$codes.Count); $w.Write([uint32]$dataOffset); $w.Write([uint32]($codes.Count * $recordSize))
    foreach ($code in $codes) {
        $record = New-Object byte[] $recordSize
        $id = 0x56; if ($layout -eq 'new') { $id = 0x113 }
        [BitConverter]::GetBytes([uint16]$id).CopyTo($record, 0)
        [BitConverter]::GetBytes([uint32]$recordSize).CopyTo($record, 2)
        $number = ConvertTo-TestIcaoNumber $code
        if ($layout -eq 'new') { [BitConverter]::GetBytes([uint64](($number -shl 6) -bor 1)).CopyTo($record, 0x4C) }
        else                   { [BitConverter]::GetBytes([uint32](($number -shl 5) -bor 1)).CopyTo($record, 0x28) }
        $w.Write($record)
    }
    [IO.File]::WriteAllBytes($path, $stream.ToArray())
}

# Writes one MSFS add-on folder: manifest.json, the given files, layout.json.
function New-TestAddon([string]$root, [string]$name, [string]$type, [string]$title, [hashtable]$files, [string]$creator = 'Some Studio') {
    $folder = Join-Path $root $name
    [void](New-Item -ItemType Directory -Path $folder -Force)
    [IO.File]::WriteAllText((Join-Path $folder 'manifest.json'), (@{ content_type = $type; title = $title; manufacturer = 'Maker'; creator = $creator } | ConvertTo-Json))
    $content = @()
    foreach ($rel in $files.Keys) {
        $full = Join-Path $folder $rel
        [void](New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force)
        $value = $files[$rel]
        if ($value -is [scriptblock]) { & $value $full } else { [IO.File]::WriteAllText($full, "$value") }
        $content += @{ path = ($rel -replace '\\', '/'); size = (Get-Item -LiteralPath $full).Length; date = 0 }
    }
    [IO.File]::WriteAllText((Join-Path $folder 'layout.json'), (@{ content = $content } | ConvertTo-Json -Depth 4))
    return $folder
}

# A scenery needs "many" files to count as a full airport; this makes filler.
function Get-Filler([int]$count) { $h = @{}; for ($i = 0; $i -lt $count; $i++) { $h["texture\t$i.dds"] = 'x' }; return $h }

$root = Join-Path ([IO.Path]::GetTempPath()) ("lhv-scan-test-" + [Guid]::NewGuid().ToString('N'))
$community = Join-Path $root 'Community'
[void](New-Item -ItemType Directory -Path $community -Force)
try {
    # ---- 1. airport codes as numbers ------------------------------------------
    Assert-Equal (ConvertFrom-LhvIcaoCode 900199) 'EDDF' 'the documented example: 900199 is EDDF'
    foreach ($code in 'EDDF', 'EDDH', 'KJFK', 'LSZH', '00C', 'EDV16', 'KHLUCKW') {
        Assert-Equal (ConvertFrom-LhvIcaoCode (ConvertTo-TestIcaoNumber $code)) $code "round trip of $code"
    }
    Assert-Equal (ConvertFrom-LhvIcaoCode 0) '' 'zero is no code'
    Assert-Equal (ConvertFrom-LhvIcaoCode 1) '' 'the unused digit 1 is rejected'

    # ---- 2. scenery files, both layouts ------------------------------------------
    $old = Join-Path $root 'old.bgl'; New-TestBgl $old @('EDDH') 'old'
    $new = Join-Path $root 'new.bgl'; New-TestBgl $new @('EDDB') 'new'
    $two = Join-Path $root 'two.bgl'; New-TestBgl $two @('EDDF', 'EDDM', 'EDDF') 'old'
    Assert-Equal @(Read-LhvBglAirports $old) @('EDDH') 'older layout: code at byte 0x28'
    Assert-Equal @(Read-LhvBglAirports $new) @('EDDB') 'MSFS 2024 layout: code at byte 0x4C'
    Assert-Equal @(Read-LhvBglAirports $two) @('EDDF', 'EDDM') 'several airports, each once'
    $junk = Join-Path $root 'junk.bgl'; [IO.File]::WriteAllBytes($junk, [byte[]](1..200))
    Assert-Equal @(Read-LhvBglAirports $junk).Count 0 'a file that is not a scenery file gives nothing'
    Assert-Equal @(Read-LhvBglAirports (Join-Path $root 'missing.bgl')).Count 0 'a missing file gives nothing'
    $cut = Join-Path $root 'cut.bgl'; [IO.File]::WriteAllBytes($cut, ([IO.File]::ReadAllBytes($old))[0..0x60])
    Assert-Equal @(Read-LhvBglAirports $cut).Count 0 'a cut-off file gives nothing and does not fail'

    # ---- 3. aircraft.cfg ------------------------------------------------------------
    Assert-Equal (ConvertTo-LhvTypeCode 'A-320 CFM SL') 'A320' 'model name with a hyphen'
    Assert-Equal (ConvertTo-LhvTypeCode 'A320 | IAE | SL') 'A320' 'model name with bars'
    Assert-Equal (ConvertTo-LhvTypeCode '777-300ER') '' 'a number is not turned into a code'
    Assert-Equal (ConvertTo-LhvTypeCode 'Airbus A350') '' 'a word is not a code'

    # ---- 4. whole add-ons -----------------------------------------------------------
    [void](New-TestAddon $community 'vendor-airport-eddh-hamburg' 'SCENERY' 'Hamburg' ((Get-Filler 20) + @{ 'scenery\world\eddh.bgl' = { param($p) New-TestBgl $p @('EDDH') 'old' } }))
    [void](New-TestAddon $community 'vendor-airport-eddb-berlin' 'SCENERY' 'Berlin' ((Get-Filler 20) + @{ 'scenery\world\a.bgl' = { param($p) New-TestBgl $p @('EDDB') 'new' }; 'scenery\world\lib.bgl' = 'not a bgl' }))
    [void](New-TestAddon $community 'no-name-at-all' 'SCENERY' 'City airport' ((Get-Filler 20) + @{ 's\x.bgl' = { param($p) New-TestBgl $p @('EDDS') 'old' } }))
    [void](New-TestAddon $community 'zz-eddf-jetway-fix' 'SCENERY' 'Jetway fix' ((Get-Filler 20) + @{ 's\x.bgl' = { param($p) New-TestBgl $p @('EDDF') 'old' } }))
    [void](New-TestAddon $community 'tiny-thing' 'SCENERY' 'Something' @{ 's\x.bgl' = { param($p) New-TestBgl $p @('EDDK') 'old' } })
    [void](New-TestAddon $community 'region-pack' 'SCENERY' 'Airfields' ((Get-Filler 20) + @{ 's\x.bgl' = { param($p) New-TestBgl $p @('EDAA','EDAB','EDAC','EDAD','EDAE','EDAF','EDAG','EDAH','EDAI','EDAJ','EDAK','EDAL','EDAM') 'old' } }))
    [void](New-TestAddon $community 'navigraph-navdata' 'SCENERY' 'Navdata' @{ 's\x.bgl' = { param($p) New-TestBgl $p @('EDDF', 'EDDM') 'old' } })
    [void](New-TestAddon $community 'bijan-tree-fix' 'SCENERY' 'Trees' @{ 's\trees.bgl' = 'x' })
    [void](New-TestAddon $community 'some-object-library' 'SCENERY' 'Objects' @{ 's\lib.bgl' = 'x' })
    [void](New-TestAddon $community 'my-home-airfield' 'SCENERY' 'My home airfield' @{ 's\x.bgl' = 'x' })
    [void](New-TestAddon $community 'coastline-italy' 'SCENERY' 'Coast' @{ 's\x.bgl' = 'x' })
    [void](New-TestAddon $community 'pmdg-aircraft-77w' 'AIRCRAFT' 'PMDG 777-300ER' @{ 'SimObjects\Airplanes\777\common\config\aircraft.cfg' = "[GENERAL]`nicao_type_designator = B77W`nicao_model = `"777-300ER`"`n[FLTSIM.0]`ntitle = `"PMDG 777`"" })
    [void](New-TestAddon $community 'fnx-aircraft-320' 'AIRCRAFT' 'Fenix A320' @{ 'SimObjects\Airplanes\FNX\presets\a\config\aircraft.cfg' = "[GENERAL]`nui_type = `"A320 | IAE | SL`""; 'SimObjects\Airplanes\FNX\attachments\b\config\aircraft.cfg' = "[GENERAL]`nicao_model = `"A-320 CFM SL`"" })
    [void](New-TestAddon $community 'ini-a350' 'AIRCRAFT' 'A350' @{ 'SimObjects\Airplanes\A350\presets\a\config\aircraft.cfg' = "icao_type_designator =A359 ULR"; 'SimObjects\Airplanes\A350\presets\b\config\aircraft.cfg' = "icao_type_designator =A35K" })
    [void](New-TestAddon $community 'mystery-jet' 'AIRCRAFT' 'Mystery' @{ 'SimObjects\Airplanes\M\aircraft.cfg' = "[FLTSIM.0]`ntitle = `"Mystery`"" })
    [void](New-TestAddon $community 'old-style-livery' 'AIRCRAFT' 'D-AIMA' @{ 'SimObjects\Airplanes\L\aircraft.cfg' = "[VARIATION]`nbase_container = `"..\A320`"" })
    [void](New-TestAddon $community 'new-style-livery' 'AIRCRAFT' 'D-AIXA' @{ 'SimObjects\Airplanes\A350\liveries\x\livery.cfg' = '[General]' })
    [void](New-TestAddon $community 'a350-cabin-pack' 'AIRCRAFT' 'Cabins' @{ 'SimObjects\Airplanes\A350\presets\c\config\aircraft.cfg' = "icao_type_designator =A359" })
    [void](New-TestAddon $community 'fsltl-traffic-base' 'AIRCRAFT' 'Traffic' @{ 'SimObjects\Airplanes\T1\aircraft.cfg' = "icao_type_designator = A320" })
    $many = @{}; $n = 0; foreach ($t in 'A318','A319','A320','A321','B737','B738','B739','B744','B748','B77W') { $many["SimObjects\Airplanes\M$n\aircraft.cfg"] = "icao_type_designator = $t"; $n++ }
    [void](New-TestAddon $community 'big-fleet-pack' 'AIRCRAFT' 'Fleet' $many)
    [void](New-TestAddon $community 'asobo-aircraft-c172' 'AIRCRAFT' 'C172' @{ 'SimObjects\Airplanes\C\aircraft.cfg' = 'icao_type_designator = C172' } 'Asobo')
    [void](New-Item -ItemType Directory -Path (Join-Path $community 'not-an-addon') -Force)

    # ---- 5. X-Plane ----------------------------------------------------------------------
    $xp = Join-Path $root 'XP'
    [void](New-Item -ItemType Directory -Path "$xp\Custom Scenery\EDDL Duesseldorf\Earth nav data" -Force)
    [IO.File]::WriteAllText("$xp\Custom Scenery\EDDL Duesseldorf\Earth nav data\apt.dat", "I`n1100 Version`n`n1   147 0 0 EDDL Duesseldorf`n100 45.00 1 0 0.25 0 2 0 05L`n17 20 0 0 xh12 Some Heliport`n")
    [void](New-Item -ItemType Directory -Path "$xp\Custom Scenery\Some_Library" -Force)
    [void](New-Item -ItemType Directory -Path "$xp\Aircraft\ToLiss A321" -Force)
    [IO.File]::WriteAllText("$xp\Aircraft\ToLiss A321\a321.acf", "I`n1200 Version`nACF`n`nP acf/_Author Someone`nP acf/_ICAO A321`nP acf/_name A321`n")

    $sims = @(
        @{ id = 'msfs2024'; name = 'MSFS 2024'; places = @(@{ path = $community; source = 'community'; kind = 'msfs' }) },
        @{ id = 'xplane12'; name = 'X-Plane 12'; places = @(@{ path = "$xp\Aircraft"; source = 'aircraft-folder'; kind = 'xp-aircraft' }, @{ path = "$xp\Custom Scenery"; source = 'custom-scenery'; kind = 'xp-scenery' }) }
    )
    $seen = New-Object System.Collections.Generic.List[string]
    $entries = @(Invoke-LhvScan -Simulators $sims -OnProgress { param($done, $total, $sim, $folder) $seen.Add("$done/$total") })
    $by = @{}; foreach ($e in $entries) { $by[$e.folder] = $e }
    $is = { param($folder) $x = $by[$folder]; "$($x.kind)|$((@($x.icaos) + @($x.aircraftTypes)) -join ',')|$([int]$x.certain)" }

    Assert-Equal $seen[$seen.Count - 1] "$($seen.Count)/$($seen.Count)" 'progress is reported for every folder'
    Assert-Equal ($by.ContainsKey('not-an-addon')) $false 'a folder without manifest.json is not an add-on'
    Assert-Equal ($by.ContainsKey('asobo-aircraft-c172')) $false 'what belongs to the simulator itself is left out'

    Assert-Equal (& $is 'vendor-airport-eddh-hamburg') 'airport|EDDH|1' 'airport, older layout'
    Assert-Equal (& $is 'vendor-airport-eddb-berlin') 'airport|EDDB|1' 'airport, MSFS 2024 layout'
    Assert-Equal (& $is 'no-name-at-all') 'airport|EDDS|1' 'the code comes from the files, not from the name'
    Assert-Equal (& $is 'zz-eddf-jetway-fix') 'airport|EDDF|0' 'a fix for an airport is not counted without a look'
    Assert-Equal (& $is 'tiny-thing') 'airport|EDDK|0' 'a handful of files is probably a fix'
    Assert-Equal ($by['region-pack'].certain) $false 'a pack with many airports needs a look'
    Assert-Equal (@($by['region-pack'].icaos).Count) 13 'the pack lists its airports'
    Assert-Equal (& $is 'navigraph-navdata') 'navdata||1' 'navigation data is not an airport scenery'
    Assert-Equal "$($by['bijan-tree-fix'].kind)/$($by['bijan-tree-fix'].detail)" 'mod/Tree fix' 'a tree fix is recognised as a mod'
    Assert-Equal $by['some-object-library'].kind 'library' 'an object library'
    Assert-Equal (& $is 'my-home-airfield') 'other||0' 'named like an airport, nothing inside: needs a look'
    Assert-Equal (& $is 'coastline-italy') 'other||1' 'a scenery without an airport is simply not counted'

    Assert-Equal (& $is 'pmdg-aircraft-77w') 'aircraft|B77W|1' 'aircraft with a type code'
    Assert-Equal (& $is 'fnx-aircraft-320') 'aircraft|A320|1' 'aircraft that only writes a model name'
    Assert-Equal (& $is 'ini-a350') 'aircraft|A359,A35K|1' 'two variants in one add-on'
    Assert-Equal (& $is 'mystery-jet') 'aircraft||0' 'an aircraft without a type needs a look'
    Assert-Equal $by['old-style-livery'].kind 'livery' 'a livery (base_container)'
    Assert-Equal $by['new-style-livery'].kind 'livery' 'a livery (livery.cfg, MSFS 2024)'
    Assert-Equal (& $is 'a350-cabin-pack') 'other||1' 'a cabin pack is a part, not an aircraft'
    Assert-Equal (& $is 'fsltl-traffic-base') 'traffic||1' 'traffic models are not aircraft you fly'
    Assert-Equal (& $is 'big-fleet-pack') 'traffic||1' 'many types in one add-on are traffic models'

    Assert-Equal (& $is 'EDDL Duesseldorf') 'airport|EDDL,XH12|1' 'X-Plane scenery: codes from apt.dat'
    Assert-Equal (& $is 'Some_Library') 'library||1' 'X-Plane folder without apt.dat'
    Assert-Equal (& $is 'ToLiss A321') 'aircraft|A321|1' 'X-Plane aircraft: type from the .acf file'

    # ---- 6. quick fix ----------------------------------------------------------------------
    $fixFile = Join-Path $root 'fixes.json'
    $fixes = @{}
    [void](Set-LhvFix $by['my-home-airfield'] 'airport' @(' edxx ', 'bad code!') @())
    Assert-Equal (& $is 'my-home-airfield') 'airport|EDXX|1' 'a fix sets kind and code, and cleans what was typed'
    Assert-Equal $by['my-home-airfield'].fixed $true 'a fixed add-on is marked'
    $fixes['MSFS 2024|my-home-airfield'] = @{ kind = 'airport'; icaos = @('EDXX'); aircraftTypes = @() }
    $fixes['MSFS 2024|mystery-jet'] = @{ kind = 'aircraft'; icaos = @(); aircraftTypes = @('A320') }
    $fixes['MSFS 2024|zz-eddf-jetway-fix'] = @{ kind = 'mod'; icaos = @(); aircraftTypes = @() }
    Save-LhvFixes $fixes $fixFile
    $again = @(Use-LhvFixes @(Invoke-LhvScan -Simulators $sims) (Read-LhvFixes $fixFile))
    $by = @{}; foreach ($e in $again) { $by[$e.folder] = $e }
    Assert-Equal (& $is 'my-home-airfield') 'airport|EDXX|1' 'the fix is remembered for the next scan'
    Assert-Equal (& $is 'mystery-jet') 'aircraft|A320|1' 'a fixed aircraft type is remembered'
    Assert-Equal (& $is 'zz-eddf-jetway-fix') 'mod||1' '"it is a mod" is remembered too'
    Assert-Equal (Read-LhvFixes (Join-Path $root 'none.json')).Count 0 'no fix file means no fixes'

    # ---- 7. the result file -------------------------------------------------------------------
    $text = ConvertTo-LhvAddonFile $again
    $file = $text | ConvertFrom-Json
    Assert-Equal $file.format 'lhv-addons/2' 'the format name'
    Assert-Equal (@($file.addons | ForEach-Object { $_.kind } | Sort-Object -Unique)) @('aircraft', 'airport') 'only airports and aircraft are listed'
    Assert-Equal (@($file.addons | Where-Object { $_.folder -eq 'tiny-thing' }).Count) 0 'what needs a look is not in the file'
    Assert-Equal (@($file.addons | Where-Object { $_.folder -eq 'my-home-airfield' })[0].fixed) $true 'a fixed add-on is in the file, marked'
    Assert-Equal ([int]$file.notListed.unclear) 2 'unclear add-ons are only counted'
    Assert-Equal ([int]$file.notListed.livery) 2 'liveries are only counted'
    Assert-Equal ($file.count) (@($file.addons).Count) 'count matches the list'
    Assert-Equal ($text.Contains($root)) $false 'no folder path in the file'
    Assert-Equal ($text -match [regex]::Escape($env:USERNAME)) $false 'no user name in the file'
    $saved = Join-Path $root 'lhv-addons.json'; Save-LhvAddonFile $again $saved
    Assert-Equal ((Get-Content -LiteralPath $saved -Raw | ConvertFrom-Json).format) 'lhv-addons/2' 'the saved file can be read back'

    Write-Host "OK: $($script:Checks) checks passed." -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
