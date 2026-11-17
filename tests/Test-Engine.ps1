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
function New-TestAddon([string]$root, [string]$name, [string]$type, [string]$title, [hashtable]$files, [string]$creator = 'Some Studio', [string]$version = '') {
    $folder = Join-Path $root $name
    [void](New-Item -ItemType Directory -Path $folder -Force)
    $manifest = @{ content_type = $type; title = $title; manufacturer = 'Maker'; creator = $creator }
    if ($version) { $manifest.package_version = $version }
    [IO.File]::WriteAllText((Join-Path $folder 'manifest.json'), ($manifest | ConvertTo-Json))
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
# Links made by the tests. They are removed one by one before the folder is
# deleted, so that deleting never follows a link.
$links = New-Object System.Collections.Generic.List[string]
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

    # ---- 6b. an add-on must not make the tool read files outside its own folder ---------------
    $secret = Join-Path $root 'outside'; [void](New-Item -ItemType Directory -Path $secret -Force)
    New-TestBgl (Join-Path $secret 'other.bgl') @('EDXX') 'old'
    [IO.File]::WriteAllText((Join-Path $secret 'aircraft.cfg'), 'icao_type_designator = B748')
    $evil = Join-Path $community 'evil-addon'; [void](New-Item -ItemType Directory -Path $evil -Force)
    [IO.File]::WriteAllText((Join-Path $evil 'manifest.json'), '{"content_type":"SCENERY","title":"Harmless","creator":"x"}')
    foreach ($path in '../../outside/other.bgl', '..\..\outside\other.bgl', '../../outside/aircraft.cfg', ((Join-Path $secret 'other.bgl') -replace '\\', '/'), 'sub/../../../outside/other.bgl') {
        [IO.File]::WriteAllText((Join-Path $evil 'layout.json'), (@{ content = @(@{ path = $path; size = 1; date = 0 }) } | ConvertTo-Json -Depth 4))
        $read = Read-LhvMsfsAddon $evil 'MSFS 2024' 'community'
        Assert-Equal "$($read.kind)|$(@($read.icaos) -join ',')|$(@($read.aircraftTypes) -join ',')" 'other||' "a file list entry that leaves the add-on is ignored: $path"
    }
    $inside = New-TestAddon $community 'honest-addon' 'SCENERY' 'Honest' ((Get-Filler 20) + @{ 'a\..\b\x.bgl' = { param($p) New-TestBgl $p @('EDDW') 'old' } })
    Assert-Equal @((Read-LhvMsfsAddon $inside 'MSFS 2024' 'community').icaos) @('EDDW') 'a path that stays inside the add-on still works'
    $odd = New-LhvEntry 'MSFS 2024' 'community' 'odd'
    [void](Set-LhvFix $odd 'something-else' @('EDDF') @())
    Assert-Equal "$($odd.kind)|$(@($odd.icaos).Count)" 'mod|1' 'an unknown kind in a fix counts as not counted'

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
    Assert-Equal (@($again | Where-Object { $_.installed }).Count) 0 'all test add-ons were made today: a moving day, no install dates'
    Assert-Equal ($text.Contains('"installed"')) $false 'no install date in the file when none is known'

    # ---- 8. add-on libraries -------------------------------------------------------------------
    # An add-on manager keeps its add-ons in a folder of its own ("Addons") and
    # links the switched-on ones into Community with a junction.
    $lib    = Join-Path $root 'Addons'
    $linkCm = Join-Path $root 'Community-linked'
    [void](New-Item -ItemType Directory -Path $linkCm -Force)
    $real = New-TestAddon $lib 'vendor-airport-eddl-duesseldorf' 'SCENERY' 'Duesseldorf' ((Get-Filler 20) + @{ 's\x.bgl' = { param($p) New-TestBgl $p @('EDDL') 'old' } }) 'Some Studio' ' 1.2.3 '
    $link = Join-Path $linkCm 'vendor-airport-eddl-duesseldorf'
    [void](New-Item -ItemType Junction -Path $link -Target $real); $links.Add($link)
    (Get-Item -LiteralPath $real).CreationTime = [datetime]'2025-03-04 10:00'     # the link itself is from today
    [void](New-TestAddon $linkCm 'plain-community-addon' 'SCENERY' 'Plain' @{ 's\x.bgl' = 'x' })
    # Switched off: only in the library, at different depths.
    [void](New-TestAddon (Join-Path $lib 'Aircraft') 'vendor-aircraft-a20n' 'AIRCRAFT' 'A320neo' @{ 'SimObjects\Airplanes\X\aircraft.cfg' = 'icao_type_designator = A20N' } 'Some Studio' '0.9.1')
    [void](New-TestAddon (Join-Path $lib 'Sceneries\Germany') 'vendor-airport-edds' 'SCENERY' 'Stuttgart' ((Get-Filler 20) + @{ 's\x.bgl' = { param($p) New-TestBgl $p @('EDDS') 'old' } }))
    [void](New-TestAddon (Join-Path $lib 'a\b\c') 'too-deep-airport' 'SCENERY' 'Deep' ((Get-Filler 20) + @{ 's\x.bgl' = { param($p) New-TestBgl $p @('EDDV') 'old' } }))
    $outer = New-TestAddon $lib 'outer-addon' 'SCENERY' 'Outer' @{ 's\x.bgl' = 'x' }
    [void](New-TestAddon $outer 'inner-addon' 'SCENERY' 'Inner' ((Get-Filler 20) + @{ 's\x.bgl' = { param($p) New-TestBgl $p @('EDDP') 'old' } }))

    $libSims = @(@{ id = 'msfs2024'; name = 'MSFS 2024'; places = @(@{ path = $linkCm; source = 'community'; kind = 'msfs' }) })
    $libs = @(Get-LhvLibraries -Simulators $libSims -UserFolders @())
    Assert-Equal $libs.Count 1 'a junction in Community leads to one library'
    Assert-Equal "$($libs[0].path)|$($libs[0].sim)|$($libs[0].fromUser)" "$(ConvertTo-LhvFolderKey $lib)|MSFS 2024|False" 'the library is the folder that holds the real add-on'
    Assert-Equal (Get-LhvLinkTarget $link) (ConvertTo-LhvFolderKey $real) 'where a junction points to'
    Assert-Equal (Get-LhvLinkTarget $real) '' 'a normal folder is not a link'
    Assert-Equal @(Get-LhvLibraries -Simulators @(@{ id = 'msfs2024'; name = 'MSFS 2024'; places = @(@{ path = $linkCm; source = 'community'; kind = 'msfs' }, @{ path = $linkCm; source = 'community'; kind = 'msfs' }) }) -UserFolders @()).Count 1 'two links into one library: listed once'

    $libEntries = @(Invoke-LhvScan -Simulators $libSims -Libraries $libs)
    $by = @{}; foreach ($e in $libEntries) { $by[$e.folder] = $e }
    Assert-Equal "$($libs[0].read)|$($libs[0].addons)|$($libs[0].linked)" 'True|4|1' 'library: four add-ons found, one of them linked'
    Assert-Equal @($libEntries | Where-Object { $_.folder -eq 'vendor-airport-eddl-duesseldorf' }).Count 1 'a linked add-on is not read twice'
    Assert-Equal $by['vendor-airport-eddl-duesseldorf'].source 'community' 'a linked add-on is read from Community'
    Assert-Equal "$($by['vendor-aircraft-a20n'].source)|$(& $is 'vendor-aircraft-a20n')" 'library|aircraft|A20N|1' 'add-on in the library at depth 2 is read'
    Assert-Equal (& $is 'vendor-airport-edds') 'airport|EDDS|1' 'add-on in the library at depth 3 is read'
    Assert-Equal ($by.ContainsKey('too-deep-airport')) $false 'add-on deeper than 3 levels is not read'
    Assert-Equal ($by.ContainsKey('inner-addon')) $false 'the search does not look inside an add-on'
    Assert-Equal $by['vendor-airport-eddl-duesseldorf'].installed '2025-03-04' 'install date of a link: the date of the real folder'
    Assert-Equal $by['vendor-airport-eddl-duesseldorf'].version '1.2.3' 'version from manifest.json, trimmed'
    Assert-Equal $by['vendor-aircraft-a20n'].version '0.9.1' 'version of a library add-on'
    Assert-Equal $by['vendor-airport-edds'].version '' 'no package_version: no version'
    Assert-Equal (Get-LhvInstallDate $real) '2025-03-04' 'install date of a normal folder: its creation date'
    $long = New-TestAddon $root 'long-version' 'SCENERY' 'Long' @{ 's\x.bgl' = 'x' } 'Some Studio' ('9' * 40)
    Assert-Equal (Read-LhvMsfsAddon $long 'MSFS 2024' 'community').version ('9' * 30) 'a version is cut after 30 characters'

    # Folders you add yourself (libraries.json).
    $libFile = Join-Path $root 'libraries.json'
    $userLib = Join-Path $root 'MyAddons'
    [void](New-TestAddon $userLib 'user-airport-edxw' 'SCENERY' 'Westerland' ((Get-Filler 20) + @{ 's\x.bgl' = { param($p) New-TestBgl $p @('EDXW') 'old' } }))
    Save-LhvLibraryFolders @($userLib) $libFile
    Assert-Equal @(Read-LhvLibraryFolders $libFile) @($userLib) 'one added folder is saved and read back as a list'
    Save-LhvLibraryFolders @($userLib, 'not a full path', (Join-Path $root 'Gone')) $libFile
    Assert-Equal @(Read-LhvLibraryFolders $libFile).Count 2 'only full paths are kept'
    Assert-Equal @(Read-LhvLibraryFolders (Join-Path $root 'none.json')).Count 0 'no library file means no added folders'
    $twoSims = @(@{ id = 'msfs2020'; name = 'MSFS 2020'; places = @() }, @{ id = 'msfs2024'; name = 'MSFS 2024'; places = @() })
    $userLibs = @(Get-LhvLibraries -Simulators $twoSims -UserFolders (Read-LhvLibraryFolders $libFile))
    Assert-Equal "$($userLibs.Count)|$($userLibs[0].sim)|$($userLibs[0].fromUser)" '1|MSFS 2024|True' 'an added folder belongs to MSFS 2024; a missing one is skipped'
    Assert-Equal @(Get-LhvLibraries -Simulators @() -UserFolders @($userLib))[0].sim 'Added folder' 'without MSFS an added folder keeps its own name'
    $userEntries = @(Invoke-LhvScan -Simulators $twoSims -Libraries $userLibs)
    Assert-Equal "$(@($userEntries).Count)|$($userEntries[0].folder)|$($userEntries[0].source)|$($userEntries[0].sim)" '1|user-airport-edxw|library|MSFS 2024' 'an add-on in an added folder is read'

    # ---- 9. moving day and the optional fields in the result file -----------------------------------
    $day = @(); for ($i = 0; $i -lt 16; $i++) { $x = New-LhvEntry 'MSFS 2024' 'community' "a$i"; $x.installed = '2026-05-01'; $day += $x }
    $other = New-LhvEntry 'MSFS 2024' 'community' 'b'; $other.installed = '2026-05-02'
    Clear-LhvMovingDay ($day + @($other))
    Assert-Equal "$(@($day | Where-Object { $_.installed }).Count)|$($other.installed)" '0|2026-05-02' '16 add-ons on one day: a move, the date is removed'
    $day = @(); for ($i = 0; $i -lt 15; $i++) { $x = New-LhvEntry 'MSFS 2024' 'community' "c$i"; $x.installed = '2026-05-01'; $day += $x }
    Clear-LhvMovingDay $day
    Assert-Equal @($day | Where-Object { $_.installed -eq '2026-05-01' }).Count 15 '15 add-ons on one day: the dates are kept'

    $with = New-LhvEntry 'MSFS 2024' 'community' 'with-date'; $with.kind = 'airport'; $with.icaos = @('EDDL'); $with.installed = '2025-03-04'; $with.version = '1.2.3'
    $without = New-LhvEntry 'MSFS 2024' 'community' 'without-date'; $without.kind = 'airport'; $without.icaos = @('EDDK')
    $text = ConvertTo-LhvAddonFile @($with, $without)
    $file = $text | ConvertFrom-Json
    $w = @($file.addons | Where-Object { $_.folder -eq 'with-date' })[0]
    $wo = @($file.addons | Where-Object { $_.folder -eq 'without-date' })[0]
    Assert-Equal "$($w.installed)|$($w.version)" '2025-03-04|1.2.3' 'installed and version are in the file when known'
    Assert-Equal (@($wo.PSObject.Properties.Name | Where-Object { $_ -eq 'installed' -or $_ -eq 'version' }).Count) 0 'installed and version are left out when not known'
    Assert-Equal $file.format 'lhv-addons/2' 'the format name stays the same'

    # ---- 10. a simulator folder is never a library ---------------------------------------------------
    # MSFS 2020 add-ons linked into the MSFS 2024 Community belong to MSFS 2020.
    $c20 = Join-Path $root 'Sim20\Community'; $c24 = Join-Path $root 'Sim24\Community'
    $shared = New-TestAddon $c20 'shared-airport' 'SCENERY' 'Shared' @{ 's\x.bgl' = 'x' }
    [void](New-TestAddon $c20 'only-2020-airport' 'SCENERY' 'Only 2020' @{ 's\x.bgl' = 'x' })
    [void](New-Item -ItemType Directory -Path $c24 -Force)
    $l = Join-Path $c24 'shared-airport'; [void](New-Item -ItemType Junction -Path $l -Target $shared); $links.Add($l)
    $s20 = @{ id = 'msfs2020'; name = 'MSFS 2020'; places = @(@{ path = $c20; source = 'community'; kind = 'msfs' }) }
    $s24 = @{ id = 'msfs2024'; name = 'MSFS 2024'; places = @(@{ path = $c24; source = 'community'; kind = 'msfs' }) }
    Assert-Equal @(Get-LhvLibraries -Simulators @($s24) -AllSimulators @($s20, $s24) -UserFolders @()).Count 0 'a link into the MSFS 2020 Community: no library, even with only MSFS 2024 ticked'
    Assert-Equal @(Get-LhvLibraries -Simulators @($s24) -UserFolders @()).Count 0 'a folder named Community is never a library, even when its sim is gone'
    Assert-Equal @(Get-LhvLibraries -Simulators @($s20) -AllSimulators @($s20, $s24) -UserFolders @($c20)).Count 0 'an added folder that is a simulator folder is not a library'
    # The same, with the 2020 folder found through another spelling (a link on the way).
    $real20 = Join-Path $root 'Sim20b\AddOnsHere'
    $other = New-TestAddon $real20 'other-airport' 'SCENERY' 'Other' @{ 's\x.bgl' = 'x' }
    $alias = Join-Path $root 'Sim20Alias'; [void](New-Item -ItemType Junction -Path $alias -Target (Join-Path $root 'Sim20b')); $links.Add($alias)
    $c24b = Join-Path $root 'Sim24b\Community'; [void](New-Item -ItemType Directory -Path $c24b -Force)
    $l = Join-Path $c24b 'other-airport'; [void](New-Item -ItemType Junction -Path $l -Target $other); $links.Add($l)
    $s20b = @{ id = 'msfs2020'; name = 'MSFS 2020'; places = @(@{ path = (Join-Path $alias 'AddOnsHere'); source = 'community'; kind = 'msfs' }) }
    $s24b = @{ id = 'msfs2024'; name = 'MSFS 2024'; places = @(@{ path = $c24b; source = 'community'; kind = 'msfs' }) }
    Assert-Equal (Resolve-LhvRealPath (Join-Path $alias 'AddOnsHere')) (ConvertTo-LhvFolderKey $real20) 'a path through a link is resolved to the real folder'
    Assert-Equal @(Get-LhvLibraries -Simulators @($s24b) -UserFolders @()).Count 1 '(without MSFS 2020 that folder would be a library)'
    Assert-Equal @(Get-LhvLibraries -Simulators @($s24b) -AllSimulators @($s20b, $s24b) -UserFolders @()).Count 0 'a simulator folder spelled through a link is still recognised'
    Assert-Equal @(Get-LhvLibraries -Simulators @($s20) -AllSimulators @($s20, $s24) -UserFolders @($userLib))[0].sim 'MSFS 2024' 'an added folder follows the sims on the PC, not the ticked ones'
    Assert-Equal (ConvertTo-LhvFolderKey '\\?\C:\Some\Folder\') 'C:\Some\Folder' 'the long-path form and a trailing backslash are normalised'

    # ---- 11. the library is the common folder of the link targets ---------------------------------
    $tree = Join-Path $root 'Tree'
    $t1 = New-TestAddon (Join-Path $tree 'Airports\EDDF') 'tree-airport-eddf' 'SCENERY' 'Frankfurt' ((Get-Filler 20) + @{ 's\x.bgl' = { param($p) New-TestBgl $p @('EDDF') 'old' } })
    $t2 = New-TestAddon (Join-Path $tree 'Aircraft\A320') 'tree-aircraft-a320' 'AIRCRAFT' 'A320' @{ 'SimObjects\Airplanes\X\aircraft.cfg' = 'icao_type_designator = A320' }
    [void](New-TestAddon (Join-Path $tree 'Aircraft\B738') 'tree-aircraft-b738' 'AIRCRAFT' 'B738' @{ 'SimObjects\Airplanes\X\aircraft.cfg' = 'icao_type_designator = B738' })
    $l = Join-Path $tree 'loop'; [void](New-Item -ItemType Junction -Path $l -Target $tree); $links.Add($l)       # a link back up: must not count twice
    $cT = Join-Path $root 'Linked-tree'; [void](New-Item -ItemType Directory -Path $cT -Force)
    foreach ($t in $t1, $t2) { $l = Join-Path $cT (Split-Path $t -Leaf); [void](New-Item -ItemType Junction -Path $l -Target $t); $links.Add($l) }
    $sT = @{ id = 'msfs2024'; name = 'MSFS 2024'; places = @(@{ path = $cT; source = 'community'; kind = 'msfs' }) }
    $libsT = @(Get-LhvLibraries -Simulators @($sT) -UserFolders @())
    Assert-Equal "$($libsT.Count)|$($libsT[0].path)" "1|$(ConvertTo-LhvFolderKey $tree)" 'links into two category folders: one library, their common folder'
    $eT = @(Invoke-LhvScan -Simulators @($sT) -Libraries $libsT)
    $by = @{}; foreach ($e in $eT) { $by[$e.folder] = $e }
    Assert-Equal "$($by['tree-aircraft-b738'].source)|$(& $is 'tree-aircraft-b738')" 'library|aircraft|B738|1' 'a switched-off add-on in a sibling category folder is found'
    Assert-Equal "$($libsT[0].addons)|$($libsT[0].linked)|$($libsT[0].stopped)" '3|2|False' 'three add-ons, two linked; a loop back up is not counted again'
    $g = @(Group-LhvLinkTargets @(@{ target = 'D:\Addons\Airports\x'; sim = 'A' }, @{ target = 'D:\Addons\Aircraft\y'; sim = 'B' }, @{ target = 'D:\Games\z'; sim = 'B' }, @{ target = 'E:\Other\w'; sim = 'A' }, @{ target = 'F:\on-the-drive'; sim = 'A' }) @())
    Assert-Equal (@($g | ForEach-Object { "$($_.path)=$($_.sim)" } | Sort-Object)) @('D:\Addons=A', 'D:\Games=B', 'E:\Other=A') 'common folder per drive; nothing in common below the drive: each its own library'
    $g = @(Group-LhvLinkTargets @(@{ target = 'G:\MSFS\Addons\a\x'; sim = 'A' }, @{ target = 'G:\MSFS\Other\y'; sim = 'A' }, @{ target = 'G:\MSFS\Community\z'; sim = 'A' }) @('G:\MSFS\Community'))
    Assert-Equal (@($g | ForEach-Object { $_.path } | Sort-Object)) @('G:\MSFS\Addons\a', 'G:\MSFS\Other') 'a common folder that holds a simulator folder is split; targets in it are left out'

    # ---- 12. a large library stops at the folder limit and says so -----------------------------------
    $big = Join-Path $root 'Big'
    for ($i = 0; $i -lt 60; $i++) { [void][IO.Directory]::CreateDirectory((Join-Path $big ('f{0:D2}' -f $i))) }
    [void](New-TestAddon $big 'zz-late-addon' 'SCENERY' 'Late' @{ 's\x.bgl' = 'x' })
    $limit = $script:MaxLibraryFolders
    try {
        $script:MaxLibraryFolders = 50
        $r = Find-LhvLibraryAddons $big
        Assert-Equal "$($r.stopped)|$($r.visited)|$(@($r.addons).Count)" 'True|50|0' 'the search stops at the folder limit'
        $libB = @{ path = $big; sim = 'MSFS 2024'; fromUser = $true; exclude = @(); read = $false; addons = 0; linked = 0; stopped = $false }
        $calls = New-Object System.Collections.Generic.List[string]
        [void](Invoke-LhvScan -Simulators @() -Libraries @($libB) -OnProgress { param($done, $total, $sim, $folder) $calls.Add("$done/$total|$folder") })
        Assert-Equal $libB.stopped $true 'the library remembers that the search stopped'
        Assert-Equal ($calls -contains "0/0|$big") $true 'searching a library is reported as progress (total 0)'
    } finally {
        $script:MaxLibraryFolders = $limit
    }
    Assert-Equal $script:MaxLibraryFolders 5000 'the folder limit is 5000'

    # ---- 13. a renamed link is still the same add-on --------------------------------------------------
    $realR = New-TestAddon (Join-Path $root 'LibRenamed') 'real-addon-name' 'SCENERY' 'Real' ((Get-Filler 20) + @{ 's\x.bgl' = { param($p) New-TestBgl $p @('EDDH') 'old' } })
    $cR = Join-Path $root 'Linked-renamed'; [void](New-Item -ItemType Directory -Path $cR -Force)
    $l = Join-Path $cR '00-renamed-link'; [void](New-Item -ItemType Junction -Path $l -Target $realR); $links.Add($l)
    $sR = @{ id = 'msfs2024'; name = 'MSFS 2024'; places = @(@{ path = $cR; source = 'community'; kind = 'msfs' }) }
    $libsR = @(Get-LhvLibraries -Simulators @($sR) -UserFolders @())
    $eR = @(Invoke-LhvScan -Simulators @($sR) -Libraries $libsR)
    Assert-Equal (@($eR | ForEach-Object { $_.folder })) @('00-renamed-link') 'a renamed link: the add-on is read once, from Community'
    Assert-Equal "$($libsR[0].addons)|$($libsR[0].linked)" '1|1' 'and counted as linked in its library'

    # ---- 14. odd values in the files ------------------------------------------------------------------
    $oddV = Join-Path $root 'odd-version'; [void](New-Item -ItemType Directory -Path $oddV -Force)
    foreach ($value in '{"a":1}', '1.5', '["1","2"]', 'null') {
        [IO.File]::WriteAllText((Join-Path $oddV 'manifest.json'), "{`"content_type`":`"SCENERY`",`"title`":`"x`",`"creator`":`"x`",`"package_version`":$value}")
        Assert-Equal (Read-LhvManifest $oddV).version '' "a package_version that is not a text gives no version: $value"
    }
    [IO.File]::WriteAllText($libFile, '["C:\\Lib", "c:\\lib\\", "C:rel", 5, null, {"a":1}]')
    Assert-Equal @(Read-LhvLibraryFolders $libFile) @('C:\Lib') 'libraries.json: one entry per folder, only full paths, only texts'

    Write-Host "OK: $($script:Checks) checks passed." -ForegroundColor Green
} finally {
    foreach ($l in $links) { try { [IO.Directory]::Delete($l) } catch { } }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
