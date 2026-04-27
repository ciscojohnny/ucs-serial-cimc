<#
.SYNOPSIS
    Configures a Cisco UCS C-Series CIMC over the serial console and preps it for Intersight claim.

.DESCRIPTION
    All tunable values (site settings, serial parameters, host IP/DNS/NTP,
    Intersight options, password rotation policy) live in a single JSONC file
    (cimc-config.jsonc) next to this script. Users only edit that file. JSONC
    supports // and /* */ comments so the file is self-documenting, and trailing
    commas are tolerated to make edits friendly for non-JSON users.

    The script picks the entry from the JSONC file whose 'hostName' matches the
    -HostName parameter (case-insensitive) and applies that configuration to
    the CIMC currently attached to -ComPort.

    Drives the CIMC CLI over a serial (COM) port to set:
        - NIC mode + NIC redundancy
        - Static IPv4 address / subnet mask / gateway
        - Primary & secondary DNS                  (from JSON)
        - Hostname                                 (from JSON)
        - DNS domain                               (from JSON)
        - Up to 4 NTP servers + timezone           (from JSON)
        - Sets a new CIMC admin password ONLY if the factory default is detected
        - Enables Intersight Device Connector

.NOTES
    Tested against CIMC 4.x / 5.x CLI (UCS C220/C240 M5/M6/M7).
    Requires PowerShell 5.1+ or 7+ on Windows with access to a serial adapter.

.EXAMPLE
    # Configure the CIMC currently attached to COM3 using the entry named 'rack01-ucs01'.
    .\Configure-CIMC.ps1 -ComPort COM3 -HostName rack01-ucs01

.EXAMPLE
    # Use a custom config file (e.g. different site)
    .\Configure-CIMC.ps1 -ComPort COM3 -HostName rack01-ucs01 -ConfigPath .\site-a.jsonc
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ComPort,

    # Match against hostName in cimc-config.jsonc (case-insensitive).
    [Parameter(Mandatory = $true)]
    [string]$HostName,

    # Path to the configuration file. Defaults to cimc-config.jsonc next to this script.
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'cimc-config.jsonc'),

    [string]$LogDirectory = (Join-Path $PSScriptRoot 'logs')
)

# -------------------- Constants that should not be edited by end users -----
$script:FactoryDefaultPassword = 'password'   # Cisco CIMC factory default
$script:CimcUsername            = 'admin'     # always 'admin' for login to a factory CIMC

# -------------------- Logging --------------------
if (-not (Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}
$script:SessionLog = Join-Path $LogDirectory ("cimc-session-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG','TX','RX')]
        [string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Add-Content -Path $script:SessionLog -Value $line
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'TX'    { Write-Host $line -ForegroundColor Cyan }
        'RX'    { Write-Verbose $line }
        'DEBUG' { Write-Verbose $line }
        default { Write-Host $line }
    }
}

# -------------------- JSONC reader --------------------
function ConvertFrom-Jsonc {
    <#
        Strip // line comments, /* */ block comments, and trailing commas
        from JSON-with-comments text, then parse it. String-aware so quoted
        sequences like "https://example.com" are preserved correctly.
    #>
    param([Parameter(Mandatory)][string]$Text)

    $sb = [System.Text.StringBuilder]::new($Text.Length)
    $inString  = $false
    $escaped   = $false
    $i         = 0
    $len       = $Text.Length

    while ($i -lt $len) {
        $c = $Text[$i]

        if ($inString) {
            [void]$sb.Append($c)
            if ($escaped)            { $escaped = $false }
            elseif ($c -eq '\')      { $escaped = $true }
            elseif ($c -eq '"')      { $inString = $false }
            $i++
            continue
        }

        if ($c -eq '"') {
            $inString = $true
            [void]$sb.Append($c)
            $i++
            continue
        }

        if ($c -eq '/' -and ($i + 1) -lt $len) {
            $next = $Text[$i + 1]
            if ($next -eq '/') {
                # Line comment: skip until newline.
                $i += 2
                while ($i -lt $len -and $Text[$i] -ne "`n") { $i++ }
                continue
            }
            if ($next -eq '*') {
                # Block comment: skip until */.
                $i += 2
                while (($i + 1) -lt $len -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
                $i += 2
                continue
            }
        }

        [void]$sb.Append($c)
        $i++
    }

    # Remove trailing commas before } or ] (allows friendlier JSON).
    $cleaned = [regex]::Replace($sb.ToString(), ',(\s*[}\]])', '$1')

    try {
        return ($cleaned | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw "Failed to parse JSON config. Underlying error: $($_.Exception.Message)"
    }
}

function Read-CimcConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $cfg = ConvertFrom-Jsonc -Text $raw

    # Validate top-level structure.
    foreach ($section in 'site','intersight','serial','behavior','servers') {
        if (-not $cfg.PSObject.Properties.Name -contains $section) {
            throw "Config file missing required section: '$section'."
        }
    }

    if ($null -eq $cfg.servers -or $cfg.servers.Count -eq 0) {
        throw "Config file '$Path' has no entries in 'servers'."
    }

    # Validate each server entry up front so we fail before touching any serial port.
    $requiredServerFields = @('hostName','ipAddress','primaryDns','dnsDomain','ntpServers')
    $seenHostNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $idx = 1
    foreach ($s in $cfg.servers) {
        foreach ($f in $requiredServerFields) {
            $val = $s.$f
            if ($null -eq $val -or ($val -is [string] -and [string]::IsNullOrWhiteSpace($val))) {
                throw "Server entry #$idx (hostName='$($s.hostName)') is missing required field '$f'."
            }
        }
        if (-not $s.ntpServers -or $s.ntpServers.Count -eq 0) {
            throw "Server entry #$idx (hostName='$($s.hostName)') must have at least one ntpServers value."
        }
        if (-not $seenHostNames.Add($s.hostName.Trim())) {
            throw "Duplicate hostName '$($s.hostName)' in config. Each hostName must be unique."
        }
        $idx++
    }

    return $cfg
}

# -------------------- Credential prompts --------------------
function Get-PlainTextFromSecure {
    param([Parameter(Mandatory)][System.Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Resolve-Credentials {
    param([Parameter(Mandatory)][object]$Config)

    # Only collect the current CIMC login password up front. A new admin
    # password is only requested later, and only if the login flow detects
    # that the CIMC is still at factory default (CIMC forces a password
    # change on first login in that case).
    $sec = Read-Host "CIMC password for '$script:CimcUsername'" -AsSecureString
    $script:CimcPassword     = Get-PlainTextFromSecure $sec
    $script:NewAdminPassword = $null
}

function Read-NewAdminPassword {
    # Interactive prompt for a new admin password with confirmation and the
    # CIMC strong-password rules. Loops until the operator gives a valid pair.
    while ($true) {
        $sec1 = Read-Host 'Factory default detected. Enter NEW admin password' -AsSecureString
        $sec2 = Read-Host 'Confirm new admin password' -AsSecureString
        $p1 = Get-PlainTextFromSecure $sec1
        $p2 = Get-PlainTextFromSecure $sec2

        if ($p1 -ne $p2) {
            Write-Host 'Passwords did not match. Try again.' -ForegroundColor Yellow
            continue
        }
        if ([string]::IsNullOrWhiteSpace($p1)) {
            Write-Host 'New admin password cannot be empty. Try again.' -ForegroundColor Yellow
            continue
        }
        if ($p1.Length -lt 8) {
            Write-Host 'New admin password must be at least 8 characters (CIMC strong-password policy). Try again.' -ForegroundColor Yellow
            continue
        }
        if ($p1 -eq $script:FactoryDefaultPassword) {
            Write-Host 'New admin password cannot be the factory default. Try again.' -ForegroundColor Yellow
            continue
        }
        return $p1
    }
}

# -------------------- Serial I/O --------------------
function Open-CimcSerial {
    param(
        [Parameter(Mandatory)][string]$PortName,
        [Parameter(Mandatory)][object]$Serial
    )

    # Evaluate casts in expression mode BEFORE the New-Object call. When an
    # expression like [int]$Serial.baudRate is written directly as an argument
    # to New-Object, PowerShell parses it in command mode and treats the
    # leading "[int]" as part of a string token (with $Serial expanded),
    # producing "[int]@{baudRate=115200; ...}.baudRate" which then fails to
    # convert to Int32.
    $baudRate  = [int]$Serial.baudRate
    $dataBits  = [int]$Serial.dataBits
    $parity    = [System.IO.Ports.Parity]   "$($Serial.parity)"
    $stopBits  = [System.IO.Ports.StopBits] "$($Serial.stopBits)"
    $handshake = [System.IO.Ports.Handshake]"$($Serial.handshake)"

    $port = New-Object -TypeName System.IO.Ports.SerialPort `
        -ArgumentList $PortName, $baudRate, $parity, $dataBits, $stopBits

    $port.Handshake    = $handshake
    $port.NewLine      = "`r"
    $port.ReadTimeout  = 2000
    $port.WriteTimeout = 2000
    $port.Encoding     = [System.Text.Encoding]::ASCII
    $port.Open()
    Start-Sleep -Milliseconds 250
    $port.DiscardInBuffer()
    $port.DiscardOutBuffer()
    return $port
}

function Read-Until {
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)][int]$TimeoutSec
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $buffer = [System.Text.StringBuilder]::new()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            if ($Port.BytesToRead -gt 0) {
                $chunk = $Port.ReadExisting()
                if ($chunk) {
                    [void]$buffer.Append($chunk)
                    Write-Log -Level RX -Message ($chunk -replace "[`r`n]+", ' | ')
                }
            } else {
                Start-Sleep -Milliseconds 100
            }
        } catch [System.TimeoutException] {
            Start-Sleep -Milliseconds 100
        }
        $current = $buffer.ToString()
        foreach ($p in $Patterns) {
            if ($current -match $p) { return $current }
        }
    }
    $tail = $buffer.ToString()
    if ($tail.Length -gt 200) { $tail = $tail.Substring($tail.Length - 200) }
    throw "Timeout waiting for pattern(s): $($Patterns -join ', '). Last 200 chars: '$tail'"
}

function Send-Command {
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][string]$Command,
        [string[]]$ExpectPatterns = @('#\s*$'),
        [int]$TimeoutSec,
        [int]$InterDelayMs,
        [switch]$Sensitive
    )
    $display = if ($Sensitive) { '<redacted>' } else { $Command }
    Write-Log -Level TX -Message "-> $display"
    $Port.WriteLine($Command)
    Start-Sleep -Milliseconds $InterDelayMs
    return (Read-Until -Port $Port -Patterns $ExpectPatterns -TimeoutSec $TimeoutSec)
}

# -------------------- Login / Logout --------------------
function Invoke-CimcLogin {
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Behavior
    )

    $loginTO  = [int]$Behavior.loginTimeoutSec
    $cmdTO    = [int]$Behavior.commandTimeoutSec
    $delayMs  = [int]$Behavior.interCommandDelayMs

    Write-Log 'Probing CIMC prompt...'
    $Port.WriteLine(''); Start-Sleep -Milliseconds 500
    $Port.WriteLine(''); Start-Sleep -Milliseconds 500

    $resp = Read-Until -Port $Port -Patterns @('login:\s*$','Password:\s*$','#\s*$') -TimeoutSec $loginTO

    if ($resp -match '#\s*$') {
        Write-Log 'Already at CIMC CLI prompt (session inherited).'
        return
    }

    if ($resp -match 'Password:\s*$') {
        $Port.WriteLine('')
        $resp = Read-Until -Port $Port -Patterns @('login:\s*$') -TimeoutSec $loginTO
    }

    Send-Command -Port $Port -Command $script:CimcUsername `
        -ExpectPatterns @('Password:\s*$') -TimeoutSec $loginTO -InterDelayMs $delayMs | Out-Null

    $pwdResp = Send-Command -Port $Port -Command $script:CimcPassword `
        -ExpectPatterns @('#\s*$','Login incorrect','Enter new password','New password:') `
        -TimeoutSec $loginTO -InterDelayMs $delayMs -Sensitive

    if ($pwdResp -match 'Login incorrect') {
        Write-Log -Level WARN 'Login incorrect with supplied password. Retrying with factory default.'
        Read-Until -Port $Port -Patterns @('login:\s*$') -TimeoutSec $loginTO | Out-Null
        Send-Command -Port $Port -Command $script:CimcUsername `
            -ExpectPatterns @('Password:\s*$') -TimeoutSec $loginTO -InterDelayMs $delayMs | Out-Null
        $pwdResp = Send-Command -Port $Port -Command $script:FactoryDefaultPassword `
            -ExpectPatterns @('#\s*$','Login incorrect','Enter new password','New password:') `
            -TimeoutSec $loginTO -InterDelayMs $delayMs -Sensitive
    }

    if ($pwdResp -match 'Login incorrect') {
        throw 'Authentication failed with both supplied and factory-default passwords.'
    }

    if ($pwdResp -match 'New password:|Enter new password') {
        Write-Log 'Factory-default password detected. CIMC requires a new admin password before first login can complete.'
        $script:NewAdminPassword = Read-NewAdminPassword
        Send-Command -Port $Port -Command $script:NewAdminPassword `
            -ExpectPatterns @('Confirm password:|Retype password:|Re-enter new password:') `
            -TimeoutSec $cmdTO -InterDelayMs $delayMs -Sensitive | Out-Null
        Send-Command -Port $Port -Command $script:NewAdminPassword `
            -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs -Sensitive | Out-Null
        $script:CimcPassword = $script:NewAdminPassword
        Write-Log 'New admin password accepted by CIMC.'
    }

    Write-Log 'CIMC login successful.'
}

function Invoke-CimcLogout {
    param([Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port)
    try {
        $Port.WriteLine('top');  Start-Sleep -Milliseconds 300
        $Port.WriteLine('exit'); Start-Sleep -Milliseconds 300
    } catch {
        Write-Log -Level WARN "Logout warning: $($_.Exception.Message)"
    }
}

# -------------------- Configuration steps --------------------
function Set-CimcNetwork {
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$PrimaryDns,
        [string]$SecondaryDns,
        [Parameter(Mandatory)][string]$DnsDomain
    )

    $site    = $Config.site
    $cmdTO   = [int]$Config.behavior.commandTimeoutSec
    $delayMs = [int]$Config.behavior.interCommandDelayMs

    Write-Log ("Configuring network: host={0} ip={1} mask={2} gw={3} dns1={4} dns2={5} domain={6}" -f `
        $Hostname, $Ip, $site.subnetMask, $site.gateway, $PrimaryDns, $SecondaryDns, $DnsDomain)

    Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'scope cimc' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'scope network' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null

    Send-Command -Port $Port -Command "set dhcp-enabled no"                     -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command "set dns-use-dhcp no"                     -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command "set mode $($site.nicMode)"               -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command "set redundancy $($site.nicRedundancy)"   -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command "set v4-addr $Ip"                         -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command "set v4-netmask $($site.subnetMask)"      -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command "set v4-gateway $($site.gateway)"         -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command "set preferred-dns-server $PrimaryDns"    -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    if ($SecondaryDns) {
        Send-Command -Port $Port -Command "set alternate-dns-server $SecondaryDns" -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    }

    # 'set hostname' on some CIMC firmware versions immediately prompts:
    #   "Create new certificate with CN as new hostname? [y|N]"
    # before the user even runs 'commit'. Drive that interaction here.
    Invoke-CimcConfirmableCommand -Port $Port -Command "set hostname $Hostname" `
        -CommandTimeoutSec $cmdTO -InterDelayMs $delayMs -Reason 'set hostname' | Out-Null

    Send-Command -Port $Port -Command "set domain-name $DnsDomain"              -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null

    if ([bool]$site.vlanEnabled) {
        Send-Command -Port $Port -Command 'set vlan-enabled yes' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        Send-Command -Port $Port -Command "set vlan-id $([int]$site.vlanId)" -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    } else {
        Send-Command -Port $Port -Command 'set vlan-enabled no' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    }

    # Changing hostname (and sometimes the IP) can trigger additional interactive
    # prompts on commit, e.g.:
    #   - "Changes will be applied. Continue? [y|N]"
    #   - "Hostname has been modified. A new certificate must be generated with
    #      the new hostname as CN. Continue? [y/N]"
    Invoke-CimcConfirmableCommand -Port $Port -Command 'commit' `
        -CommandTimeoutSec 30 -InterDelayMs $delayMs -Reason 'network commit' | Out-Null

    Write-Log 'Network commit accepted.'
}

# Sends a command that may produce one or more interactive yes/no prompts
# (e.g. [y|N], [y/N], "Continue?", "Create new certificate ... [y|N]") before
# returning to the CIMC CLI '#' prompt. Answers 'y' to each prompt up to a
# bounded number of confirmations and then returns the final response.
function Invoke-CimcConfirmableCommand {
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][int]$CommandTimeoutSec,
        [Parameter(Mandatory)][int]$InterDelayMs,
        [string]$Reason = 'command',
        [int]$MaxConfirmations = 5
    )

    # Match the various confirmation prompts CIMC firmware uses. Note the
    # literal "[y|N]" form (pipe), which is what 'set hostname' shows on the
    # firmware that previously timed out.
    $promptRegex = '\[y\|N\]|\[y/N\]|\[y/n\]|continue\?|regenerat.*certificate|hostname.*changed|create new certificate'

    $resp = Send-Command -Port $Port -Command $Command `
        -ExpectPatterns @('#\s*$', $promptRegex) `
        -TimeoutSec $CommandTimeoutSec -InterDelayMs $InterDelayMs

    $remaining = $MaxConfirmations
    while ($resp -match $promptRegex -and $resp -notmatch '#\s*$' -and $remaining -gt 0) {
        if ($resp -match 'regenerat.*certificate|hostname.*changed|create new certificate') {
            Write-Log "$Reason - accepting certificate regeneration prompt with new hostname as CN."
        } else {
            Write-Log "$Reason - confirming prompt with 'y'."
        }
        $resp = Send-Command -Port $Port -Command 'y' `
            -ExpectPatterns @('#\s*$', $promptRegex) `
            -TimeoutSec $CommandTimeoutSec -InterDelayMs $InterDelayMs
        $remaining--
    }

    if ($resp -notmatch '#\s*$') {
        throw "$Reason did not return to CLI prompt after answering confirmations. Last response: '$resp'"
    }
    return $resp
}

function Set-CimcNtp {
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string[]]$NtpServers
    )

    $cmdTO   = [int]$Config.behavior.commandTimeoutSec
    $delayMs = [int]$Config.behavior.interCommandDelayMs

    $ntp = @($NtpServers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 4)
    if ($ntp.Count -eq 0) {
        Write-Log -Level WARN 'No NTP servers supplied; skipping NTP config.'
        return
    }

    Write-Log "Configuring NTP: $($ntp -join ', ')"

    Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'scope cimc' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'scope network' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'scope ntp' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec 10 -InterDelayMs $delayMs | Out-Null

    # CIMC requires NTP to be enabled and committed BEFORE 'set server-N' will
    # accept NTP server addresses. Doing both in a single commit silently drops
    # the server entries on some firmware. Enable + commit first, then load the
    # servers and commit again.
    Write-Log 'Enabling NTP service (commit #1) before configuring NTP server slots.'
    # 'set enabled yes' on the NTP scope can prompt:
    #   "Warning: IPMI Set SEL Time command will be disabled if NTP is enabled.
    #    Do you wish to continue? [y/N]"
    Invoke-CimcConfirmableCommand -Port $Port -Command 'set enabled yes' `
        -CommandTimeoutSec $cmdTO -InterDelayMs $delayMs -Reason 'NTP set enabled yes' | Out-Null

    Invoke-CimcConfirmableCommand -Port $Port -Command 'commit' `
        -CommandTimeoutSec 20 -InterDelayMs $delayMs -Reason 'NTP enable commit' | Out-Null

    # Verify NTP is actually enabled before we try to load server addresses.
    $ntpStatus = Send-Command -Port $Port -Command 'show detail' `
        -ExpectPatterns @('#\s*$') -TimeoutSec 15 -InterDelayMs $delayMs
    if ($ntpStatus -notmatch '(?im)^\s*NTP\s+(Enabled|Service|Status)?\s*[:=]\s*(yes|enabled|true)') {
        Write-Log -Level WARN ("NTP did not report as enabled after commit; continuing anyway. show detail output:`n" + $ntpStatus)
    } else {
        Write-Log 'NTP service confirmed enabled.'
    }

    Write-Log 'Loading NTP server slots (commit #2).'
    $slots = @('server-1','server-2','server-3','server-4')
    for ($i = 0; $i -lt $slots.Count; $i++) {
        if ($i -lt $ntp.Count) {
            Send-Command -Port $Port -Command ("set {0} {1}" -f $slots[$i], $ntp[$i]) `
                -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        } else {
            Send-Command -Port $Port -Command ("set {0} ''" -f $slots[$i]) `
                -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        }
    }

    Invoke-CimcConfirmableCommand -Port $Port -Command 'commit' `
        -CommandTimeoutSec 20 -InterDelayMs $delayMs -Reason 'NTP servers commit' | Out-Null

    # Read-back so the log captures the final NTP state for forensics.
    $finalNtp = Send-Command -Port $Port -Command 'show detail' `
        -ExpectPatterns @('#\s*$') -TimeoutSec 15 -InterDelayMs $delayMs
    Write-Log ("Post-commit NTP state:`n" + $finalNtp)

    if (-not [string]::IsNullOrWhiteSpace($Config.site.timezone)) {
        Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        Send-Command -Port $Port -Command 'scope cimc' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        $tzResp = Send-Command -Port $Port -Command ("set-timezone {0}" -f $Config.site.timezone) `
            -ExpectPatterns @('#\s*$','Invalid','Unrecognized') -TimeoutSec 10 -InterDelayMs $delayMs
        if ($tzResp -match 'Invalid|Unrecognized') {
            Send-Command -Port $Port -Command 'scope clock' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
            Send-Command -Port $Port -Command ("set timezone {0}" -f $Config.site.timezone) `
                -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
            Invoke-CimcConfirmableCommand -Port $Port -Command 'commit' `
                -CommandTimeoutSec $cmdTO -InterDelayMs $delayMs -Reason 'timezone commit' | Out-Null
        }
    }
    Write-Log 'NTP configured.'
}

function Enable-IntersightDeviceConnector {
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Config
    )

    if (-not [bool]$Config.intersight.enableDeviceConnector) { return }

    $cmdTO   = [int]$Config.behavior.commandTimeoutSec
    $delayMs = [int]$Config.behavior.interCommandDelayMs

    Write-Log 'Enabling Intersight Device Connector (Cloud management).'

    Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    $resp = Send-Command -Port $Port -Command 'scope cloud' -ExpectPatterns @('#\s*$','Invalid scope') -TimeoutSec 10 -InterDelayMs $delayMs
    if ($resp -match 'Invalid scope') {
        Send-Command -Port $Port -Command 'scope device-connector' -ExpectPatterns @('#\s*$','Invalid scope') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    }

    Send-Command -Port $Port -Command 'set enabled yes'                -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'set read-only-mode no'          -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'set tunneled-kvm-enabled yes'   -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'set auto-update-enabled yes'    -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null

    if ($Config.intersight.proxyHost) {
        Send-Command -Port $Port -Command 'set proxy-enabled yes' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        Send-Command -Port $Port -Command ("set proxy-host {0}" -f $Config.intersight.proxyHost) -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        if ($Config.intersight.proxyPort) {
            Send-Command -Port $Port -Command ("set proxy-port {0}" -f [int]$Config.intersight.proxyPort) -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        }
    }

    Invoke-CimcConfirmableCommand -Port $Port -Command 'commit' `
        -CommandTimeoutSec 20 -InterDelayMs $delayMs -Reason 'Intersight commit' | Out-Null
}

# -------------------- Inventory helpers --------------------
function Get-ServerEntry {
    param(
        [Parameter(Mandatory)][object[]]$Servers,
        [Parameter(Mandatory)][string]$HostName
    )
    $match = @($Servers | Where-Object { $_.hostName -and ($_.hostName.Trim() -ieq $HostName.Trim()) })
    if ($match.Count -eq 0) {
        $known = ($Servers | ForEach-Object { $_.hostName }) -join ', '
        throw "hostName '$HostName' not found in config. Known hosts: $known"
    }
    return $match[0]
}

# -------------------- Per-server driver --------------------
function Invoke-ConfigureServer {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Server
    )

    $hn     = $Server.hostName.Trim()
    $ip     = $Server.ipAddress.Trim()
    $dns1   = $Server.primaryDns.Trim()
    $dns2   = if ($Server.PSObject.Properties.Name -contains 'secondaryDns' -and $Server.secondaryDns) { $Server.secondaryDns.Trim() } else { '' }
    $domain = $Server.dnsDomain.Trim()
    $ntp    = @($Server.ntpServers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    Write-Log "===== Starting configuration for $hn ($ip) on $ComPort ====="

    if ([System.IO.Ports.SerialPort]::GetPortNames() -notcontains $ComPort) {
        throw "COM port '$ComPort' not found. Available: $([System.IO.Ports.SerialPort]::GetPortNames() -join ', ')"
    }

    $port = $null
    try {
        $port = Open-CimcSerial -PortName $ComPort -Serial $Config.serial
        Invoke-CimcLogin           -Port $port -Behavior $Config.behavior
        Set-CimcNetwork            -Port $port -Config $Config -Ip $ip -Hostname $hn `
                                   -PrimaryDns $dns1 -SecondaryDns $dns2 -DnsDomain $domain
        Start-Sleep -Seconds 3
        Set-CimcNtp                -Port $port -Config $Config -NtpServers $ntp
        Enable-IntersightDeviceConnector -Port $port -Config $Config
        Invoke-CimcLogout          -Port $port
        Write-Log "===== Finished configuration for $hn ($ip) ====="
    }
    catch {
        Write-Log -Level ERROR "Failed configuring $hn ($ip): $($_.Exception.Message)"
        throw
    }
    finally {
        if ($port -and $port.IsOpen) { $port.Close(); $port.Dispose() }
    }
}

# -------------------- Entrypoint --------------------
try {
    Write-Log "Log file:    $script:SessionLog"
    Write-Log "Config file: $ConfigPath"

    $Config = Read-CimcConfig -Path $ConfigPath
    Resolve-Credentials -Config $Config

    $server = Get-ServerEntry -Servers $Config.servers -HostName $HostName
    Write-Host ''
    Write-Host "Configuring $($server.hostName) -> $($server.ipAddress) on $ComPort" -ForegroundColor Cyan
    Invoke-ConfigureServer -Config $Config -Server $server

    Write-Host ''
    Write-Host "Done. Log: $script:SessionLog" -ForegroundColor Green
}
catch {
    Write-Log -Level ERROR $_.Exception.Message
    Write-Host ''
    Write-Host "FAILED. See log: $script:SessionLog" -ForegroundColor Red
    exit 1
}
