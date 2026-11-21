@echo off
setlocal EnableExtensions

rem ============================================================
rem  CMCC HN-18 modem: auto-export + decrypt lastgood.xml
rem  Double-click to run. Output goes to "export_auto" folder
rem  next to this .bat.
rem  Precondition (do once in a browser):
rem    1. Login to http://192.168.1.1
rem    2. Visit /webcmcc/config_upgrade.html and click export
rem    (telnet is auto-enabled by the script if needed)
rem  All content is plain ASCII, so no codepage issues.
rem ============================================================
if not defined CMCC_OUT_DIR set "CMCC_OUT_DIR=%~dp0export_auto"

rem Run the PowerShell embedded between ###PS### and ###END_PS###
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c=[System.IO.File]::ReadAllText('%~f0',[System.Text.Encoding]::UTF8); $a=[regex]::Match($c,'(?m)^###PS###[ \t]*\r?$'); $b=[regex]::Match($c,'(?m)^###END_PS###[ \t]*\r?$'); if(-not $a.Success){Write-Host 'embedded PowerShell not found'; exit 2}; $end=$c.Length; if($b.Success -and $b.Index -gt $a.Index){$end=$b.Index}; $ps=$c.Substring($a.Index+$a.Length,$end-($a.Index+$a.Length)).TrimStart(); $t=[System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),'cmcc_'+[guid]::NewGuid().ToString('N')+'.ps1'); [System.IO.File]::WriteAllText($t,$ps,(New-Object System.Text.UTF8Encoding($true))); & powershell -NoProfile -ExecutionPolicy Bypass -File $t; $r=$LASTEXITCODE; Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue; exit $r"

set "RC=%ERRORLEVEL%"

if "%RC%"=="0" (
    echo.
    echo DONE. Export folder: "%CMCC_OUT_DIR%"
    echo Open result.txt for the admin password.
) else (
    echo.
    echo FAILED with exit code %RC%. See messages above.
)
echo.
pause
exit /b %RC%

###PS###
param(
    [string]$ModemIp = '192.168.1.1',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'

$script:ModemIp    = $ModemIp
$script:OutDir     = $OutDir
if (-not $script:OutDir) { $script:OutDir = $env:CMCC_OUT_DIR }
if (-not $script:OutDir) { $script:OutDir = Join-Path (Get-Location).Path 'export_auto' }
$script:TelnetPort = 23
$script:TelnetUser = 'user'
$script:TelnetPass = 'nE7jA%5m'

$script:Tcp       = $null
$script:Stream    = $null
$script:Eof       = $false
$script:IacState  = 'data'
$script:IacCmd    = 0
$script:Ascii     = New-Object System.Text.ASCIIEncoding
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Log([string]$Message) { Write-Host $Message }

# ==================== Minimal telnet client ====================

function Convert-TelnetChunk {
    param([byte[]]$Data, [int]$Count)
    $plain = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $Count; $i++) {
        $b = $Data[$i]
        switch ($script:IacState) {
            'data' {
                if ($b -eq 255)      { $script:IacState = 'iac' }
                elseif ($b -eq 0 -or $b -eq 17) { }   # ignore NUL / XON
                else                  { [void]$plain.Add($b) }
            }
            'iac' {
                if ($b -eq 255)            { [void]$plain.Add(255); $script:IacState = 'data' }
                elseif ($b -ge 251 -and $b -le 254) { $script:IacCmd = $b; $script:IacState = 'opt' }
                elseif ($b -eq 250)        { $script:IacState = 'sub' }
                else                       { $script:IacState = 'data' }
            }
            'opt' {
                # Same as Python telnetlib defaults: DO/DONT -> WONT, WILL/WONT -> DONT
                $reply = $null
                if ($script:IacCmd -eq 253 -or $script:IacCmd -eq 254) { $reply = 252 }
                elseif ($script:IacCmd -eq 251 -or $script:IacCmd -eq 252) { $reply = 254 }
                if ($null -ne $reply -and $script:Stream -and -not $script:Eof) {
                    try {
                        $r = [byte[]](255, $reply, $b)
                        $script:Stream.Write($r, 0, 3)
                        $script:Stream.Flush()
                    } catch { }
                }
                $script:IacState = 'data'
            }
            'sub'    { if ($b -eq 255) { $script:IacState = 'subIac' } }
            'subIac' { if ($b -eq 240) { $script:IacState = 'data' } else { $script:IacState = 'sub' } }
        }
    }
    if ($plain.Count -eq 0) { return '' }
    return $script:Ascii.GetString($plain.ToArray())
}

function Read-Loop {
    param(
        [int]$TimeoutSec = 20,
        [int]$IdleMs = 0,
        [scriptblock]$Done
    )
    $sb       = New-Object System.Text.StringBuilder
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $lastData = [DateTime]::UtcNow
    $rx       = New-Object byte[] 8192
    while ($true) {
        $cur = $sb.ToString()
        if ($Done -and (& $Done $cur)) { return $cur }
        $remainMs = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remainMs -le 0) { break }
        $pollUs = [int][Math]::Min(100000, $remainMs * 1000)
        $ready = $false
        try { $ready = $script:Tcp.Client.Poll($pollUs, [System.Net.Sockets.SelectMode]::SelectRead) } catch { break }
        if ($ready) {
            $n = 0
            try { $n = $script:Stream.Read($rx, 0, $rx.Length) } catch { break }
            if ($n -le 0) { $script:Eof = $true; break }
            $lastData = [DateTime]::UtcNow
            $chunk = Convert-TelnetChunk -Data $rx -Count $n
            if ($chunk.Length -gt 0) { [void]$sb.Append($chunk) }
            continue
        }
        if ($IdleMs -gt 0 -and ([DateTime]::UtcNow - $lastData).TotalMilliseconds -ge $IdleMs) { break }
    }
    return $sb.ToString()
}

function Read-Until {
    param(
        [string[]]$Patterns,
        [int]$TimeoutSec = 20,
        [string]$What = ''
    )
    $done = {
        param([string]$s)
        foreach ($p in $Patterns) { if ($s.Contains($p)) { return $true } }
        return $false
    }
    $out = Read-Loop -TimeoutSec $TimeoutSec -Done $done
    foreach ($p in $Patterns) { if ($out.Contains($p)) { return $out } }
    $label = $What
    if (-not $label) { $label = ($Patterns -join ' / ') }
    $snippet = $out
    if ($snippet.Length -gt 150) { $snippet = $snippet.Substring($snippet.Length - 150) }
    throw ("Timed out waiting for [{0}]. Recent output: {1}" -f $label, ($snippet -replace "`r`n", ' '))
}

function Connect-Telnet {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.ReceiveTimeout = 500
    $tcp.SendTimeout    = 5000
    $tcp.Connect($script:ModemIp, $script:TelnetPort)
    $script:Tcp      = $tcp
    $script:Stream   = $tcp.GetStream()
    $script:Eof      = $false
    $script:IacState = 'data'
}

function Send-Telnet([string]$Text) {
    $bytes = $script:Ascii.GetBytes($Text)
    $list  = New-Object System.Collections.Generic.List[byte]
    foreach ($b in $bytes) {
        [void]$list.Add($b)
        if ($b -eq 255) { [void]$list.Add(255) }
    }
    $arr = $list.ToArray()
    $script:Stream.Write($arr, 0, $arr.Length)
    $script:Stream.Flush()
}

function Close-Telnet {
    if ($script:Stream) { try { $script:Stream.Close() } catch { } }
    if ($script:Tcp)    { try { $script:Tcp.Close() } catch { } }
    $script:Stream = $null
    $script:Tcp    = $null
}

function Enable-TelnetOnModem {
    try {
        $nonce = Get-Random -Minimum 100000 -Maximum 999999
        $body  = "mode_name=/boaform/set_telenet_enabled_mod&nonedata=0.$nonce&telenet_enabled=1&user_name=user&user_password=nE7jA%255m"
        $uri   = "http://$($script:ModemIp)/boaform/set_telenet_enabled_mod.cgi"
        $resp  = Invoke-WebRequest -Uri $uri -Method Post -Body $body `
                    -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 10
        if ($resp.Content -match 'SUCCESS') { return $true }
        Write-Log ("  Web interface replied: {0}" -f (($resp.Content -replace '\s+', ' ').Trim()))
        return $false
    } catch {
        Write-Log ("  Request failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Open-Session {
    $lastErr = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Log ("Connecting to {0}:{1} ... (attempt {2})" -f $script:ModemIp, $script:TelnetPort, $attempt)
        try {
            Connect-Telnet
            $banner = Read-Until -Patterns @('login:') -TimeoutSec 12 -What 'login prompt'
            Write-Log ("  Connected: {0}" -f (($banner -replace "`r?`n", ' ').Trim()))
            Send-Telnet ($script:TelnetUser + "`n")
            $null = Read-Until -Patterns @('assword:') -TimeoutSec 10 -What 'password prompt'
            Send-Telnet ($script:TelnetPass + "`n")
            $after = Read-Loop -TimeoutSec 15 -Done { param($s) $s.Contains('$ ') }
            if (-not $after.Contains('$ ')) {
                if ($after -match 'Login incorrect|incorrect') { throw 'bad username or password' }
                throw 'no shell prompt after login'
            }
            Send-Telnet "`n"
            $null = Read-Until -Patterns @('$ ') -TimeoutSec 8 -What 'shell prompt'
            Write-Log ("  Logged in (user: {0})" -f $script:TelnetUser)
            return
        } catch {
            $lastErr = $_.Exception.Message
            Write-Log ("  Failed: {0}" -f $lastErr)
            Close-Telnet
            if ($attempt -lt 3) {
                Write-Log '  Trying web interface to enable telnet ...'
                if (Enable-TelnetOnModem) { Write-Log '  Enable request sent' }
                Start-Sleep -Seconds 4
            }
        }
    }
    throw ("Cannot reach modem telnet (last error: {0}). " +
           "Open http://{1}/webcmcc/telnet.html in a browser first, then retry.") -f $lastErr, $script:ModemIp
}

# Run one command and read until the shell prompt (command must not contain "$ ")
function Invoke-Simple {
    param([string]$Command, [int]$TimeoutSec = 30)
    Send-Telnet ($Command + "`n")
    return Read-Until -Patterns @('$ ') -TimeoutSec $TimeoutSec -What ("command: " + $Command)
}

# Fetch one remote file: md5sum + base64 + end marker, then verify locally
function Get-RemoteFile {
    param(
        [string]$RemotePath,
        [string]$LocalPath,
        [int]$Idx,
        [int]$TimeoutSec = 90
    )
    $marker = "__END_${Idx}_${Idx}__"
    # The command echo contains __END_1_$(echo 1)__, never the literal marker
    $cmd = "md5sum $RemotePath; base64 $RemotePath; echo __END_${Idx}_`$(echo ${Idx})__"
    Send-Telnet ($cmd + "`n")
    $out = Read-Loop -TimeoutSec $TimeoutSec -Done { param($s) $s.Contains($marker) }
    $null = Read-Loop -TimeoutSec 4 -IdleMs 400     # consume the prompt after the marker

    if (-not $out.Contains($marker)) {
        throw ("Timed out reading {0} (file may not exist or be unreadable)" -f $RemotePath)
    }

    $body   = $out.Substring(0, $out.IndexOf($marker))
    $devMd5 = $null
    $b64    = New-Object System.Collections.Generic.List[string]
    $seenMd5 = $false
    foreach ($line in ($body -split "`n")) {
        $s = $line.Trim()
        if (-not $s) { continue }
        if (-not $seenMd5) {
            $m = [regex]::Match($s, '^([0-9a-f]{32})\s+\S')
            if ($m.Success) { $devMd5 = $m.Groups[1].Value; $seenMd5 = $true }
            continue
        }
        if ($s -match '^[A-Za-z0-9+/=]+$') { [void]$b64.Add($s) }
    }
    if (-not $devMd5) { throw ("Failed to read {0}: no md5sum output (file may not exist)" -f $RemotePath) }
    if ($b64.Count -eq 0) { throw ("Failed to read {0}: modem returned no base64 data (is 'base64' available?)" -f $RemotePath) }

    $joined = ($b64 -join '')
    $pad = 4 - ($joined.Length % 4)
    if ($pad -eq 4) { $pad = 0 }
    if ($pad -gt 0) { $joined += ('=' * $pad) }

    try { $bytes = [Convert]::FromBase64String($joined) }
    catch { throw ("base64 decode failed for {0}: {1}" -f $RemotePath, $_.Exception.Message) }

    [System.IO.File]::WriteAllBytes($LocalPath, $bytes)
    $localMd5 = (Get-FileHash -LiteralPath $LocalPath -Algorithm MD5).Hash.ToLower()
    $ok = ($localMd5 -eq $devMd5)
    if ($ok) {
        Write-Log ("    OK  {0} bytes" -f $bytes.Length)
    } else {
        Write-Log ("    [MD5 mismatch] local {0} / modem {1}" -f $localMd5, $devMd5)
    }
    return @{ Ok = $ok; LocalMd5 = $localMd5; RemoteMd5 = $devMd5; Size = $bytes.Length }
}

function Get-DirBlock {
    param([string]$Text, [string]$DirName)
    $m = [regex]::Match($Text, '(?s)<Dir Name="' + [regex]::Escape($DirName) + '">.*?</Dir>')
    if ($m.Success) { return $m.Value }
    return ''
}

function Get-BlockValue {
    param([string]$Block, [string]$Name)
    if (-not $Block) { return '' }
    $m = [regex]::Match($Block, '<Value Name="' + [regex]::Escape($Name) + '" Value="([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Get-AnyValue {
    param([string]$Text, [string]$Name)
    if (-not $Text) { return '' }
    $m = [regex]::Match($Text, '<Value Name="' + [regex]::Escape($Name) + '" Value="([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Get-SysinfoValue {
    param([string]$Text, [string]$Tag)
    if (-not $Text) { return '' }
    $m = [regex]::Match($Text, '<' + [regex]::Escape($Tag) + ' value="([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Format-Mac {
    param([string]$Mac)
    if ($Mac -match '^[0-9A-Fa-f]{12}$') {
        $pairs = @()
        for ($i = 0; $i -lt 12; $i += 2) { $pairs += $Mac.Substring($i, 2) }
        return ($pairs -join ':').ToUpper()
    }
    return $Mac
}

function Fmt-Field {
    param([string]$Label, [string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { $Value = '(none)' }
    return ("  {0,-20}: {1}" -f $Label, $Value)
}

# Build the one-page cheat sheet needed when replacing the modem
function Get-CheatSheet {
    param([string]$DecText, [string]$SysText)

    $teleUser = Get-AnyValue $DecText 'aucTeleAccountName'
    $telePass = Get-AnyValue $DecText 'aucTeleAccountPassword'
    $userAcct = Get-AnyValue $DecText 'aucUserAccountName'
    $userPass = Get-AnyValue $DecText 'aucUserAccountPassword'

    # Find the INTERNET WAN connection block
    $wanBlocks = [regex]::Matches($DecText, '(?s)<Dir Name="WAN_CONNECTION_ATTR_TAB">.*?</Dir>')
    $wan = ''
    foreach ($m in $wanBlocks) {
        if ((Get-BlockValue $m.Value 'aucWanName') -match 'INTERNET') { $wan = $m.Value; break }
    }
    if (-not $wan) {
        foreach ($m in $wanBlocks) {
            if (Get-BlockValue $m.Value 'aucUsername') { $wan = $m.Value; break }
        }
    }
    $pppUser = Get-BlockValue $wan 'aucUsername'
    $pppPass = Get-BlockValue $wan 'aucPassword'
    $wanName = Get-BlockValue $wan 'aucWanName'
    $wanIf   = Get-BlockValue $wan 'aucWanIfName'
    $wanMac  = Format-Mac (Get-BlockValue $wan 'aucMACAddress')

    $vlan = Get-BlockValue $wan 'ulVlanIdMark'
    if ((-not $vlan) -or $vlan -eq '0') {
        if ($wanName -match 'VID_(\d+)')      { $vlan = $Matches[1] }
        elseif ($wanIf -match '_(\d+)$')       { $vlan = $Matches[1] }
    }

    # OLT registration credentials (Password auth or LOID)
    $pwdDir  = Get-DirBlock $DecText 'REMOTEMGT_PASSWORD_REG_ATTR_TAB'
    $regPass = Get-BlockValue $pwdDir 'aucPasswd'
    if (-not $regPass) { $regPass = Get-SysinfoValue $SysText 'reg_id' }
    $loidDir  = Get-DirBlock $DecText 'REMOTEMGT_LOID_REG_ATTR_TAB'
    $loidName = Get-BlockValue $loidDir 'aucLoidName'
    $loidPwd  = Get-BlockValue $loidDir 'aucLoidPasswd'
    if (-not $loidName) { $loidName = Get-SysinfoValue $SysText 'loid' }
    if (-not $loidPwd)  { $loidPwd  = Get-SysinfoValue $SysText 'lopwd' }
    if ($regPass)          { $authType = 'Password' }
    elseif ($loidName)     { $authType = 'LOID' }
    else                   { $authType = 'unknown' }

    $gponSn = Get-AnyValue $DecText 'aucGPONSN'
    if (-not $gponSn) { $gponSn = Get-SysinfoValue $SysText 'product_sn' }
    $devMac = Get-AnyValue $DecText 'aucGateWayMac'
    if (-not $devMac) { $devMac = Get-SysinfoValue $SysText 'gateway_mac' }

    # TR069 remote management
    $trDir    = Get-DirBlock $DecText 'REMOTEMGT_TR069_ATTR_TAB'
    $acsUrl   = Get-BlockValue $trDir 'aucAcsUrl'
    $cpeUser  = Get-BlockValue $trDir 'aucUsername'
    $cpePass  = Get-BlockValue $trDir 'aucPassword'
    $connUser = Get-BlockValue $trDir 'aucConnReqUsername'
    $connPass = Get-BlockValue $trDir 'aucConnReqPassword'

    # Device info from sysinfo.xml
    $model = Get-SysinfoValue $SysText 'equipment_id'
    $hwVer = Get-SysinfoValue $SysText 'hw_version'
    $swVer = Get-SysinfoValue $SysText 'sw_version'
    $mfr   = Get-SysinfoValue $SysText 'manufacturer'
    $prov  = Get-SysinfoValue $SysText 'province'
    $ctei  = Get-SysinfoValue $SysText 'ctei'

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $l  = @()
    $l += '============================================================'
    $l += ' MIGRATION CHEAT SHEET  (old modem -> new modem)'
    $l += (" Modem: {0}    Time: {1}" -f $script:ModemIp, $ts)
    $l += '============================================================'
    $l += ''
    $l += '[Web login]'
    $l += (Fmt-Field 'Superadmin account'  $teleUser)
    $l += (Fmt-Field 'Superadmin password' $telePass)
    $l += (Fmt-Field 'User account'        $userAcct)
    $l += (Fmt-Field 'User password'       $userPass)
    $l += ''
    $l += '[PPPoE / Internet]'
    $l += (Fmt-Field 'Account'    $pppUser)
    $l += (Fmt-Field 'Password'   $pppPass)
    $l += (Fmt-Field 'VLAN ID'    $vlan)
    $l += (Fmt-Field 'WAN name'   $wanName)
    $l += (Fmt-Field 'WAN MAC'    $wanMac)
    $l += ''
    $l += '[ONT registration]'
    $l += (Fmt-Field 'Auth type'      $authType)
    $l += (Fmt-Field 'Password auth'  $regPass)
    $l += (Fmt-Field 'LOID'           $loidName)
    $l += (Fmt-Field 'LOID password'  $loidPwd)
    $l += (Fmt-Field 'SN / GPON SN'   $gponSn)
    $l += (Fmt-Field 'Device MAC'     $devMac)
    $l += ''
    $l += '[TR069 remote management]'
    $l += (Fmt-Field 'ACS URL'         $acsUrl)
    $l += (Fmt-Field 'CPE account'     $cpeUser)
    $l += (Fmt-Field 'CPE password'    $cpePass)
    $l += (Fmt-Field 'ConnReq account' $connUser)
    $l += (Fmt-Field 'ConnReq password' $connPass)
    $l += ''
    $l += '[Device info]'
    $l += (Fmt-Field 'Model'        $model)
    $l += (Fmt-Field 'Hardware'     $hwVer)
    $l += (Fmt-Field 'Software'     $swVer)
    $l += (Fmt-Field 'Manufacturer' $mfr)
    $l += (Fmt-Field 'Province'     $prov)
    $l += (Fmt-Field 'CTEI'         $ctei)
    $l += ''
    $l += '============================================================'
    $l += ' Full decrypted config: 02_lastgood_decrypted_current.xml'
    $l += '============================================================'
    return ($l -join "`r`n")
}

# ==================== Main ====================

$exitCode = 1
try {
    Write-Log ''
    Write-Log '===== CMCC modem lastgood.xml auto-export ====='
    Write-Log ("Modem: {0}" -f $script:ModemIp)

    Open-Session

    Write-Log '[1/5] Checking /tmp/config_file.tar.gz ...'
    $chk = Invoke-Simple 'ls -l /tmp/config_file.tar.gz'
    if ($chk -notmatch 'config_file\.tar\.gz') {
        throw @"
/tmp/config_file.tar.gz not found. Do the web export first:
  1. Open http://$($script:ModemIp) in a browser and log in
  2. Visit http://$($script:ModemIp)/webcmcc/config_upgrade.html
  3. Click "Config File Export" and confirm
  4. Run this script again
"@
    }
    Write-Log '  Found.'

    Write-Log '[2/5] Extracting config package to /tmp/hn18 ...'
    $null = Invoke-Simple 'mkdir -p /tmp/hn18'
    $tarOut = Invoke-Simple 'tar xzf /tmp/config_file.tar.gz -C /tmp/hn18'
    $lst = Invoke-Simple 'ls -la /tmp/hn18'
    if ($lst -notmatch 'lastgood\.xml') { throw 'tar package has no lastgood.xml; firmware layout may differ' }
    Write-Log '  Extraction done.'

    Write-Log '[3/5] Decrypting lastgood.xml ...'
    $dec1 = Invoke-Simple 'hi_ipc /home/cmd/encrypt/decrypt_file -v ifile /config/work/lastgood.xml ofile /tmp/cmcc_lastgood_dec.xml' -TimeoutSec 45
    if ($dec1 -notmatch 'succ') {
        throw ("Failed to decrypt current config: {0}" -f (($dec1 -replace '\s+', ' ').Trim()))
    }
    Write-Log '  Current config (/config/work) decrypted.'
    $dec2 = Invoke-Simple 'hi_ipc /home/cmd/encrypt/decrypt_file -v ifile /tmp/hn18/lastgood.xml ofile /tmp/hn18/lastgood_dec.xml' -TimeoutSec 45
    if ($dec2 -notmatch 'succ') {
        throw ("Failed to decrypt export package: {0}" -f (($dec2 -replace '\s+', ' ').Trim()))
    }
    Write-Log '  Export package (/tmp/hn18) decrypted.'

    Write-Log ('[4/5] Exporting files to {0} ...' -f $script:OutDir)
    New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null

    $exportList = @(
        @{ Remote = '/tmp/config_file.tar.gz';        Local = '01_config_file.tar.gz' },
        @{ Remote = '/tmp/cmcc_lastgood_dec.xml';     Local = '02_lastgood_decrypted_current.xml' },
        @{ Remote = '/tmp/hn18/lastgood_dec.xml';     Local = '03_lastgood_decrypted_export.xml' },
        @{ Remote = '/config/work/lastgood.xml';      Local = '04_lastgood_encrypted_current.xml' },
        @{ Remote = '/tmp/hn18/lastgood.xml';         Local = '05_lastgood_encrypted_export.xml' },
        @{ Remote = '/config/work/backup_lastgood.xml'; Local = '06_backup_lastgood.xml' },
        @{ Remote = '/config/workb/lastgood.xml';     Local = '07_workb_lastgood.xml' },
        @{ Remote = '/config/work/defaultconfig.xml'; Local = '08_defaultconfig.xml' },
        @{ Remote = '/tmp/hn18/factory.txt';          Local = '09_factory.txt' },
        @{ Remote = '/tmp/hn18/sysinfo.xml';          Local = '10_sysinfo.xml' },
        @{ Remote = '/tmp/hn18/board.xml';            Local = '11_board.xml' },
        @{ Remote = '/tmp/hn18/bob_config.ini';       Local = '12_bob_config.ini' },
        @{ Remote = '/tmp/sipapp.xml';                Local = '13_sipapp.xml' },
        @{ Remote = '/tmp/province';                  Local = '14_province.txt' }
    )

    $manifest = @()
    $failed   = @()
    for ($i = 0; $i -lt $exportList.Count; $i++) {
        $f = $exportList[$i]
        $idx = $i + 1
        $localPath = Join-Path $script:OutDir $f.Local
        Write-Log ('  [{0}/{1}] {2}' -f $idx, $exportList.Count, $f.Remote)
        try {
            $r = Get-RemoteFile -RemotePath $f.Remote -LocalPath $localPath -Idx $idx -TimeoutSec 90
            $status = if ($r.Ok) { 'OK' } else { 'MD5_MISMATCH' }
            $manifest += ("{0}  {1}  <=  {2}  [{3}]" -f $r.LocalMd5, $f.Local, $f.Remote, $status)
            if (-not $r.Ok) { $failed += ($f.Remote + ' (MD5 mismatch)') }
        } catch {
            Write-Log ('    Failed: {0}' -f $_.Exception.Message)
            $failed += ($f.Remote + ' (' + $_.Exception.Message + ')')
            $null = Read-Loop -TimeoutSec 10 -IdleMs 1500
        }
    }

    Write-Log '[5/5] Building migration cheat sheet ...'
    $decPath = Join-Path $script:OutDir '02_lastgood_decrypted_current.xml'
    $decText = [System.IO.File]::ReadAllText($decPath, [System.Text.Encoding]::UTF8)
    $sysPath = Join-Path $script:OutDir '10_sysinfo.xml'
    $sysText = ''
    if (Test-Path -LiteralPath $sysPath) {
        $sysText = [System.IO.File]::ReadAllText($sysPath, [System.Text.Encoding]::UTF8)
    }

    $cheat = Get-CheatSheet -DecText $decText -SysText $sysText
    [System.IO.File]::WriteAllText((Join-Path $script:OutDir 'result.txt'), $cheat, $script:Utf8NoBom)

    $mf = "CMCC modem config export manifest`r`nsource: $($script:ModemIp)`r`n`r`n"
    $mf += "md5(remote-verified)  local_file  <=  remote_path`r`n"
    $mf += ($manifest -join "`r`n")
    [System.IO.File]::WriteAllText((Join-Path $script:OutDir 'manifest.txt'), $mf, $script:Utf8NoBom)

    if ($failed.Count -eq 0) {
        Write-Log ''
        Write-Log ("All done. Files in: {0}" -f $script:OutDir)
        $exitCode = 0
    } else {
        Write-Log ''
        Write-Log ("{0} file(s) failed to export:" -f $failed.Count)
        foreach ($x in $failed) { Write-Log ("  - {0}" -f $x) }
        $exitCode = 1
    }

    Write-Log ''
    Write-Log $cheat
} catch {
    Write-Log ''
    Write-Log ("[Error] {0}" -f $_.Exception.Message)
    $exitCode = 1
} finally {
    Close-Telnet
}

exit $exitCode

###END_PS###
