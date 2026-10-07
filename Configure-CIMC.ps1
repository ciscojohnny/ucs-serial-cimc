<#
.SYNOPSIS
    Configures a Cisco UCS C-Series CIMC over the serial console and preps it for Intersight claim.

.DESCRIPTION
    Edit cimc-config.jsonc, then run this script against the CIMC on -ComPort.
    It applies the "servers" entry whose hostName matches -HostName.

    Order of operations:
        1. Log in. Change the admin password only if CIMC is still at factory default.
        2. Set NIC mode, static IPv4, DNS, hostname, and DNS domain.
        3. Enable NTP, load the NTP servers, and set the timezone.
        4. Enable the Intersight Device Connector.
        5. If firmware.enabled is true (or -Firmware is passed), serve the HUU
           ISO and have CIMC update and activate every component except the
           drives. CIMC boots the ISO as part of that job.

.NOTES
    Standalone CIMC only (not UCS Manager). Tested on C220 M7S with CIMC 6.0
    and C220 M7N with CIMC 4.3. M5/M6/M7 share the CLI shape; command text and
    the HUU XML fields do not. Keep both forms when they differ:
      Timezone: timezone-select. Newer menus say "Central Time"; older menus
        say "Central (most areas)". Leave the menu with answers, not Ctrl-C.
      Device Connector: settings live in scope device-connector or scope cloud.
        On 4.3, scope cimc / scope device-connector is the firmware-update
        scope. If "set enabled" is rejected, do not commit; that commit hangs.
      HUU www map: 6.0 takes remoteIp "http://host:port", remoteShare
        "/file.iso", plus bootMedium. On ISO Mapping Error, retry without
        those 6.0-only fields, then with a bare IP and the full http URL.
      updateComponent "all" skips drives. "all,hdd" includes them.
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

    [string]$LogDirectory = (Join-Path $PSScriptRoot 'logs'),

    # Run the HUU upgrade this time, even when firmware.enabled is false.
    [switch]$Firmware,

    # Override firmware.isoFile and firmware.isoFolder for this run.
    [string]$IsoFile,
    [string]$IsoFolder
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

    $port = [System.IO.Ports.SerialPort]::new(
        $PortName,
        [int]$Serial.baudRate,
        [System.IO.Ports.Parity]$Serial.parity,
        [int]$Serial.dataBits,
        [System.IO.Ports.StopBits]$Serial.stopBits
    )
    $port.Handshake    = [System.IO.Ports.Handshake]$Serial.handshake
    $port.NewLine      = "`r"
    $port.ReadTimeout  = 2000
    $port.WriteTimeout = 2000
    $port.Encoding     = [System.Text.Encoding]::ASCII
    # Assert DTR/RTS before opening. The Cisco serial console and many USB-serial
    # adapters (e.g. Prolific PL2303) require these control lines high before they
    # will send/receive data; without them a fresh console stays completely silent.
    $port.DtrEnable    = $true
    $port.RtsEnable    = $true
    $port.Open()
    Start-Sleep -Milliseconds 250
    $port.DiscardInBuffer()
    $port.DiscardOutBuffer()
    return $port
}

function Invoke-PortToggle {
    # Open and immediately close the serial device in a SEPARATE short-lived
    # process. After a CIMC management-console reset (first-time password change,
    # reboot/factory reset) the console stays mute until the serial connection is
    # physically dropped and reopened. Empirically (confirmed against SecureCRT
    # and standalone probes) an in-process .NET Close()/Dispose() + reopen does
    # NOT drive the DTR/RTS lines low->high at the macOS driver level, but a fresh
    # process open/close does (the OS guarantees the handle is released and the
    # control lines drop when the child exits). So we shell out to a tiny child
    # pwsh whose only job is to toggle the lines, exactly like clicking "connect"
    # in SecureCRT. -EncodedCommand avoids all nested-quoting pitfalls.
    param(
        [Parameter(Mandatory)][string]$PortName,
        [Parameter(Mandatory)][int]$Baud
    )
    $child = "try { `$q=[System.IO.Ports.SerialPort]::new('$PortName',$Baud); " +
             "`$q.DtrEnable=`$true; `$q.RtsEnable=`$true; `$q.Open(); " +
             "Start-Sleep -Milliseconds 700; `$q.Close(); `$q.Dispose() } catch {}"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($child))
    try { & pwsh -NoProfile -EncodedCommand $enc 2>$null | Out-Null } catch {}
}

function Reset-CimcPort {
    # Perform a TRUE drop/reconnect that wakes a parked CIMC console. We must (1)
    # release our own OS handle, (2) toggle the control lines from a SEPARATE
    # process (see Invoke-PortToggle - this is the part an in-process reopen
    # cannot do reliably on macOS), then (3) open a brand-new port in this
    # process to drive the rest of the session. Returns the new port (also stored
    # in $script:Port), or $null if the reopen failed (caller should retry).
    param([Parameter(Mandatory)][AllowNull()][System.IO.Ports.SerialPort]$Port)
    try { if ($Port -and $Port.IsOpen) { $Port.Close() } } catch {}
    try { if ($Port) { $Port.Dispose() } } catch {}
    Start-Sleep -Milliseconds 600
    # Real OS-level line toggle from a child process (mimics SecureCRT reconnect).
    Invoke-PortToggle -PortName $script:PortName -Baud ([int]$script:SerialConfig.baudRate)
    Start-Sleep -Milliseconds 600
    try {
        $new = Open-CimcSerial -PortName $script:PortName -Serial $script:SerialConfig
        $script:Port = $new
        return $new
    } catch {
        return $null
    }
}

function Send-WakeSequence {
    # The Cisco UCS serial console sits parked/blank (no banner, no prompt) until
    # it receives the ESC+9 escape sequence, which switches the serial port over
    # to the CIMC login prompt - this is the manual "press ESC then 9 in SecureCRT
    # to see the login prompt" step. A bare CR/LF (or a DTR/RTS toggle alone) does
    # NOT wake it. Send ESC, then '9', then a CR so the login banner renders, with
    # small gaps so the console treats it as a real ESC sequence rather than noise.
    param([Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port)
    try {
        $Port.Write([string][char]27)   # ESC
        Start-Sleep -Milliseconds 200
        $Port.Write('9')
        Start-Sleep -Milliseconds 200
        $Port.Write("`r")
        Start-Sleep -Milliseconds 500
    } catch {}
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
        # AllowEmptyString: map-www prompts for a username/password even on an
        # open HTTP share. A blank Enter is the correct answer, and Windows
        # PowerShell rejects a Mandatory string that is empty.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
        [string[]]$ExpectPatterns = @('#\s*$'),
        [int]$TimeoutSec,
        [int]$InterDelayMs,
        [switch]$Sensitive
    )
    $display = if ($Sensitive) { '<redacted>' } elseif ([string]::IsNullOrEmpty($Command)) { '<blank>' } else { $Command }
    Write-Log -Level TX -Message "-> $display"
    $Port.WriteLine($Command)
    Start-Sleep -Milliseconds $InterDelayMs
    return (Read-Until -Port $Port -Patterns $ExpectPatterns -TimeoutSec $TimeoutSec)
}

# -------------------- Login / Logout --------------------
# -------------------- Prompt patterns (CIMC serial console) --------------------
# Centralised so the login probe and the password-change handler stay in sync.
# Observed M7 wording (CIMC 4.x/5.x):
#   "[<host>] Username:"            login prompt (NOT "login:")
#   "Password:"                     password prompt
#   "Enter current password:"       forced-change step 1
#   "Enter new password:"           forced-change step 2
#   "Re-enter new password:"        forced-change step 3
# NOTE: "Re-enter new password:" also contains "new password:", so callers MUST
#       test $script:RxConfirmPwd BEFORE $script:RxNewPwd to disambiguate.
$script:RxUser       = '(?i)(?:Username|login):\s*$'
$script:RxPass       = '(?i)Password:\s*$'
$script:RxCli        = '#\s*$'
$script:RxCurrentPwd = '(?i)current password:\s*$'
$script:RxNewPwd     = '(?i)new password:\s*$'
$script:RxConfirmPwd = '(?i)(?:re-?enter|re-?type|confirm)[^\r\n]*password:\s*$'
$script:RxLoginFail  = '(?i)(login incorrect|login failed|permission denied|authentication fail|does not match|password mismatch|invalid password|username/password is wrong)'

# Interactive confirmation prompts CIMC can raise after a 'set'/'commit'
# (e.g. "Do you wish to continue? [y/N]", certificate regeneration). Kept here
# so every call site answers them the same way.
$script:RxConfirm = 'y\|N|\[y/N\]|\[y/n\]|continue\?|certificate'

function Send-CimcConfirm {
    <#
        Send a command and automatically answer any interactive confirmation
        prompt(s) by replying 'y' until the CLI prompt (#) returns. Use this for
        any command that may pop a "[y/N]" confirmation. Returns the final
        accumulated console text.
    #>
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
        [int]$TimeoutSec = 20,
        [int]$InterDelayMs = 250,
        [int]$MaxConfirm = 5,
        [switch]$Sensitive
    )
    $resp = Send-Command -Port $Port -Command $Command `
        -ExpectPatterns @($script:RxCli, $script:RxConfirm) `
        -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs -Sensitive:$Sensitive
    $n = $MaxConfirm
    while ($resp -match $script:RxConfirm -and $resp -notmatch $script:RxCli -and $n -gt 0) {
        Write-Log 'Auto-confirming CIMC prompt with "y".'
        $resp = Send-Command -Port $Port -Command 'y' `
            -ExpectPatterns @($script:RxCli, $script:RxConfirm) `
            -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs
        $n--
    }
    return $resp
}

function Sync-CimcPrompt {
    <#
        Get the reader back in step with the console. Discards buffered text and
        nudges with Enter until the '#' prompt comes back, so a read that has
        drifted a prompt behind (or a momentarily quiet console) cannot starve
        the next command. Returns $true when we end at a prompt.

        Deliberately does NOT send the ESC+9 wake sequence: that is for a parked
        PRE-LOGIN console and would switch the serial port away mid-session.
    #>
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [int]$Attempts = 3,
        [int]$TimeoutSec = 5
    )
    for ($i = 0; $i -lt $Attempts; $i++) {
        try { $Port.DiscardInBuffer() } catch {}
        try {
            $Port.Write("`r")
            $resp = Read-Until -Port $Port -Patterns @($script:RxCli) -TimeoutSec $TimeoutSec
            if ($resp -match $script:RxCli) { return $true }
        } catch {}
    }
    return $false
}

function Restore-CimcCli {
    # A commit in the wrong scope can leave the serial CLI silent. Enter often
    # does nothing then. Ctrl-C returns to the prompt without the ESC+9 wake,
    # which would switch away from an already-open session.
    param([Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port)
    if (Sync-CimcPrompt -Port $Port -Attempts 2 -TimeoutSec 3) { return $true }
    Write-Log 'Serial console is quiet. Sending Ctrl-C to return to the prompt.'
    try { $Port.Write([string][char]3) } catch {}
    Start-Sleep -Milliseconds 400
    return (Sync-CimcPrompt -Port $Port -Attempts 3 -TimeoutSec 4)
}

function Send-CimcBestEffort {
    <#
        Send an OPTIONAL command. If the console answers nothing before the
        timeout, log a warning, resync the prompt and carry on rather than
        throwing. Use this for settings that must never abort a run whose real
        configuration has already been committed.

        Input is drained first so a stale prompt left over from a previous
        command cannot satisfy this command's read (that drift is what starved
        the Device Connector settings on C220 M7N).

        Returns the console text, or $null when the command produced no reply.
    #>
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
        [int]$TimeoutSec = 20,
        [int]$InterDelayMs = 250
    )
    try { $Port.DiscardInBuffer() } catch {}
    try {
        return (Send-CimcConfirm -Port $Port -Command $Command -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs)
    }
    catch {
        Write-Log -Level WARN "No console reply to '$Command' within ${TimeoutSec}s; treating it as optional and continuing."
        if (-not (Sync-CimcPrompt -Port $Port)) {
            Write-Log -Level WARN 'Could not resync the CIMC prompt after the silent command.'
        }
        return $null
    }
}

function Invoke-PasswordChange {
    <#
        Drives the CIMC forced password-change dialog. Can be entered either
        right after sending the login password, or when the console is already
        parked somewhere inside the dialog (StartResp tells us where).
    #>
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentPwd,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StartResp,
        [Parameter(Mandatory)][object]$Behavior
    )

    $cmdTO   = [int]$Behavior.commandTimeoutSec
    $delayMs = [int]$Behavior.interCommandDelayMs
    $resp    = $StartResp

    # Step 1: "Enter current password:" -> resend the current/default password.
    if ($resp -match $script:RxCurrentPwd) {
        Write-Log 'Password change: supplying current password.'
        $resp = Send-Command -Port $Port -Command $CurrentPwd `
            -ExpectPatterns @($script:RxConfirmPwd, $script:RxNewPwd, $script:RxCli, $script:RxLoginFail) `
            -TimeoutSec $cmdTO -InterDelayMs $delayMs -Sensitive
        if ($resp -match $script:RxLoginFail -and $resp -notmatch $script:RxNewPwd) {
            throw 'CIMC rejected the current password during the forced password change.'
        }
    }

    # Collect (and validate) the new admin password from the operator.
    $newPwd = Read-NewAdminPassword

    # Step 2: "Enter new password:" -> send the new password.
    if ($resp -notmatch $script:RxNewPwd -or $resp -match $script:RxConfirmPwd) {
        $resp = Read-Until -Port $Port -Patterns @($script:RxNewPwd, $script:RxConfirmPwd) -TimeoutSec $cmdTO
    }
    if ($resp -notmatch $script:RxConfirmPwd) {
        $resp = Send-Command -Port $Port -Command $newPwd `
            -ExpectPatterns @($script:RxConfirmPwd, $script:RxCli, $script:RxLoginFail) `
            -TimeoutSec $cmdTO -InterDelayMs $delayMs -Sensitive
    }

    # Step 3: "Re-enter new password:" -> confirm the new password.
    # On this firmware a first-time password change takes the management console
    # FULLY OFFLINE for several minutes (observed ~5 min) while the BMC applies
    # the change/restarts. When it returns it sits at the login prompt but will
    # NOT reprint "Username:" on a bare Enter, so we must speculatively send the
    # username to elicit "Password:" and then log in with the NEW password.
    if ($resp -match $script:RxConfirmPwd) {
        $Port.WriteLine($newPwd)
        Start-Sleep -Milliseconds $delayMs

        $script:CimcPassword     = $newPwd
        $script:NewAdminPassword = $newPwd

        Write-Log 'New password submitted. CIMC takes the console offline for several minutes after a first-time change; waiting for it to recover and re-login...'

        $recoverTO = 600   # seconds (10 min) - observed ~5 min recovery
        $loggedIn  = $false
        $waited    = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $loggedIn -and $waited.Elapsed.TotalSeconds -lt $recoverTO) {
            Start-Sleep -Seconds 10

            # Recreate the port (fresh handle, like reconnecting in SecureCRT),
            # then ESC+9 to bring the login prompt back to the serial line.
            $Port = Reset-CimcPort -Port $Port
            if (-not $Port) { continue }
            try { $Port.DiscardInBuffer() } catch { continue }
            # Wake/redirect the serial console to the CIMC login prompt (ESC+9).
            Send-WakeSequence -Port $Port

            # Speculatively send the username; a live console answers "Password:".
            $uResp = $null
            try {
                $uResp = Send-Command -Port $Port -Command $script:CimcUsername `
                    -ExpectPatterns @($script:RxPass, $script:RxCli) -TimeoutSec 6 -InterDelayMs $delayMs
            }
            catch {
                $secs = [int]$waited.Elapsed.TotalSeconds
                Write-Log "Console still offline after the password change (${secs}s elapsed); continuing to wait..."
                continue
            }

            if ($uResp -match $script:RxCli) { $loggedIn = $true; break }

            if ($uResp -match $script:RxPass) {
                $pResp = Send-Command -Port $Port -Command $newPwd `
                    -ExpectPatterns @($script:RxCli, $script:RxLoginFail, $script:RxCurrentPwd, $script:RxNewPwd) `
                    -TimeoutSec 15 -InterDelayMs $delayMs -Sensitive
                if ($pResp -match $script:RxCli) { $loggedIn = $true; break }
                if ($pResp -match $script:RxLoginFail) {
                    throw 'Re-login after the password change failed: the new password was not accepted.'
                }
                if ($pResp -match $script:RxCurrentPwd -or $pResp -match $script:RxNewPwd) {
                    throw 'CIMC re-prompted for a password change after the new password was submitted (change may not have applied).'
                }
            }
        }

        if (-not $loggedIn) {
            throw "CIMC console did not recover within ${recoverTO}s after the password change."
        }

        Write-Log 'Re-login after the password change succeeded. New admin password accepted by CIMC.'
        return
    }

    # Fallback: we never reached the confirm prompt (unexpected dialog shape).
    if ($resp -match $script:RxLoginFail -or $resp -match $script:RxNewPwd) {
        throw 'Password change failed (CIMC rejected the new password - likely a strong-password policy violation or mismatch). Try again.'
    }

    $script:CimcPassword     = $newPwd
    $script:NewAdminPassword = $newPwd

    if ($resp -match $script:RxUser) {
        Write-Log 'CIMC requires re-login after the password change; logging in with the new password.'
        Send-Command -Port $Port -Command $script:CimcUsername `
            -ExpectPatterns @($script:RxPass) -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        Send-Command -Port $Port -Command $newPwd `
            -ExpectPatterns @($script:RxCli, $script:RxLoginFail) -TimeoutSec $cmdTO -InterDelayMs $delayMs -Sensitive | Out-Null
    }
    elseif ($resp -notmatch $script:RxCli) {
        Send-Command -Port $Port -Command '' `
            -ExpectPatterns @($script:RxCli, $script:RxUser) -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    }

    Write-Log 'New admin password accepted by CIMC.'
}

function Invoke-CimcLogin {
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Behavior
    )

    $loginTO  = [int]$Behavior.loginTimeoutSec
    $delayMs  = [int]$Behavior.interCommandDelayMs

    Write-Log 'Probing CIMC prompt...'

    # The console may be OFFLINE (still booting after a factory reset/reboot - can
    # take several minutes) or parked at a login prompt that will NOT reprint
    # "Username:" on a bare Enter. Patiently establish a known state: detect the
    # CLI (#) or a password-change prompt, or get to "Password:" by speculatively
    # sending the username. Retry for several minutes to ride through a booting
    # console instead of failing on the first silent attempt.
    $bootTO    = [Math]::Max($loginTO, 600)
    $atPass    = $false
    $waited     = [System.Diagnostics.Stopwatch]::StartNew()
    $firstPass  = $true
    while (-not $atPass -and $waited.Elapsed.TotalSeconds -lt $bootTO) {
        if (-not $firstPass) {
            Start-Sleep -Seconds 10
            # Recreate the port (fresh handle), then ESC+9 below wakes the console.
            $Port = Reset-CimcPort -Port $Port
            if (-not $Port) { continue }
        }
        $firstPass = $false

        try { $Port.DiscardInBuffer() } catch {}
        # Wake/redirect the serial console to the CIMC login prompt (ESC+9).
        Send-WakeSequence -Port $Port

        # See if the console volunteers a recognizable prompt first.
        $resp = ''
        try {
            $resp = Read-Until -Port $Port `
                -Patterns @($script:RxUser, $script:RxPass, $script:RxCli, $script:RxCurrentPwd, $script:RxConfirmPwd, $script:RxNewPwd) `
                -TimeoutSec 4
        } catch { $resp = '' }

        if ($resp -match $script:RxCli) {
            Write-Log 'Already at CIMC CLI prompt (session inherited).'
            return
        }

        # Console parked mid password-change dialog (e.g. from a prior attempt):
        # finish the change. Test confirm before new because "Re-enter new
        # password:" also matches the new-password pattern.
        if ($resp -match $script:RxCurrentPwd -or $resp -match $script:RxConfirmPwd -or $resp -match $script:RxNewPwd) {
            Write-Log 'Console is parked at a password-change prompt; completing the password change.'
            Invoke-PasswordChange -Port $Port -CurrentPwd $script:CimcPassword -StartResp $resp -Behavior $Behavior
            Write-Log 'CIMC login successful (completed a pending password change).'
            return
        }

        # Speculatively send the username; a live login console answers "Password:".
        $uResp = ''
        try {
            $uResp = Send-Command -Port $Port -Command $script:CimcUsername `
                -ExpectPatterns @($script:RxPass, $script:RxCli) -TimeoutSec 6 -InterDelayMs $delayMs
        }
        catch {
            $secs = [int]$waited.Elapsed.TotalSeconds
            Write-Log "Console not responding yet (${secs}s elapsed); waiting (CIMC may still be booting)..."
            continue
        }

        if ($uResp -match $script:RxCli) {
            Write-Log 'Already at CIMC CLI prompt (session inherited).'
            return
        }
        if ($uResp -match $script:RxPass) { $atPass = $true; break }
    }

    if (-not $atPass) {
        throw "CIMC console did not present a login prompt within ${bootTO}s (still offline/booting?)."
    }

    # We are at "Password:" - send the password.
    $pwdResp = Send-Command -Port $Port -Command $script:CimcPassword `
        -ExpectPatterns @($script:RxCli, $script:RxLoginFail, $script:RxCurrentPwd, $script:RxNewPwd) `
        -TimeoutSec $loginTO -InterDelayMs $delayMs -Sensitive

    if ($pwdResp -match $script:RxLoginFail) {
        Write-Log -Level WARN 'Login incorrect with supplied password. Retrying with factory default.'
        Read-Until -Port $Port -Patterns @($script:RxUser) -TimeoutSec $loginTO | Out-Null
        Send-Command -Port $Port -Command $script:CimcUsername `
            -ExpectPatterns @($script:RxPass) -TimeoutSec $loginTO -InterDelayMs $delayMs | Out-Null
        $pwdResp = Send-Command -Port $Port -Command $script:FactoryDefaultPassword `
            -ExpectPatterns @($script:RxCli, $script:RxLoginFail, $script:RxCurrentPwd, $script:RxNewPwd) `
            -TimeoutSec $loginTO -InterDelayMs $delayMs -Sensitive
        if ($pwdResp -notmatch $script:RxLoginFail) {
            $script:CimcPassword = $script:FactoryDefaultPassword
        }
    }

    if ($pwdResp -match $script:RxLoginFail) {
        throw 'Authentication failed with both supplied and factory-default passwords.'
    }

    if ($pwdResp -match $script:RxCurrentPwd -or $pwdResp -match $script:RxNewPwd) {
        Write-Log 'Factory-default password detected. CIMC requires an admin password change before first login can complete.'
        Invoke-PasswordChange -Port $Port -CurrentPwd $script:CimcPassword -StartResp $pwdResp -Behavior $Behavior
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

    # Interactive [y|N] confirmations that CIMC can raise either right after a
    # command (e.g. "set hostname" -> "Create new certificate ... [y|N]") or at
    # commit time. Matched in one place so both call sites stay consistent.
    $promptRegex = 'y\|N|\[y/N\]|\[y/n\]|continue\?|certificate|hostname.*changed'

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
    # On some firmware "set hostname" immediately prompts:
    #   "Create new certificate with CN as new hostname? [y|N]"
    # Answer 'y' to any such prompt(s) before continuing. Use a longer timeout
    # because accepting can trigger certificate regeneration.
    $hostResp = Send-Command -Port $Port -Command "set hostname $Hostname" `
        -ExpectPatterns @('#\s*$', $promptRegex) -TimeoutSec $cmdTO -InterDelayMs $delayMs
    $maxHostConfirm = 5
    while ($hostResp -match $promptRegex -and $hostResp -notmatch '#\s*$' -and $maxHostConfirm -gt 0) {
        Write-Log 'Confirming certificate-regeneration prompt for hostname change with "y".'
        $hostResp = Send-Command -Port $Port -Command 'y' `
            -ExpectPatterns @('#\s*$', $promptRegex) -TimeoutSec 30 -InterDelayMs $delayMs
        $maxHostConfirm--
    }
    # CIMC 'scope network' has NO static DNS domain: "set domain-name" is rejected
    # as an invalid command. A domain is only configurable via Dynamic DNS
    # ('set ddns-update-domain'). Attempt it best-effort; if the firmware rejects
    # it (DDNS disabled/unsupported), warn and continue rather than failing.
    $domResp = Send-Command -Port $Port -Command "set ddns-update-domain $DnsDomain" `
        -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs
    if ($domResp -match '(?i)invalid|error|\^\s') {
        Write-Log -Level WARN ("DNS domain '$DnsDomain' was NOT applied: CIMC network scope has no static domain (DDNS may be disabled). Output: " + ($domResp -replace '[\r\n]+',' '))
    } else {
        Write-Log "DNS domain set via DDNS update-domain: $DnsDomain"
    }

    if ([bool]$site.vlanEnabled) {
        Send-Command -Port $Port -Command 'set vlan-enabled yes' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        Send-Command -Port $Port -Command "set vlan-id $([int]$site.vlanId)" -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    } else {
        Send-Command -Port $Port -Command 'set vlan-enabled no' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    }

    # Disable IPv6 on the CIMC management interface (default on; staged here and
    # applied by the network commit below). 'v6-enabled' is a network-scope
    # property. Honour an explicit "disableIpv6": false to leave IPv6 untouched.
    $disableV6 = if ($site.PSObject.Properties.Name -contains 'disableIpv6') { [bool]$site.disableIpv6 } else { $true }
    if ($disableV6) {
        Write-Log 'Disabling IPv6 on the CIMC management interface.'
        Send-Command -Port $Port -Command 'set v6-enabled no' `
            -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    }

    # Changing hostname (and sometimes the IP) triggers one or more interactive
    # prompts on commit, including:
    #   - "Changes will be applied. Continue? [y|N]"
    #   - "Hostname has been modified. A new certificate must be generated with
    #      the new hostname as CN. Continue? [y/N]"
    # Loop and answer 'y' to each one until we are returned to the CLI prompt.
    $resp = Send-Command -Port $Port -Command 'commit' `
        -ExpectPatterns @('#\s*$', $promptRegex) `
        -TimeoutSec 30 -InterDelayMs $delayMs

    $maxConfirmations = 5
    while ($resp -match $promptRegex -and $resp -notmatch '#\s*$' -and $maxConfirmations -gt 0) {
        if ($resp -match 'regenerat.*certificate|hostname.*changed') {
            Write-Log 'Hostname changed - accepting certificate regeneration prompt with new hostname as CN.'
        } else {
            Write-Log 'Confirming commit prompt with "y".'
        }
        $resp = Send-Command -Port $Port -Command 'y' `
            -ExpectPatterns @('#\s*$', $promptRegex) `
            -TimeoutSec 30 -InterDelayMs $delayMs
        $maxConfirmations--
    }

    if ($resp -notmatch '#\s*$') {
        throw "Network commit did not return to CLI prompt after answering confirmations. Last response: '$resp'"
    }
    Write-Log 'Network commit accepted.'
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
    # "set enabled yes" warns: "IPMI Set SEL Time command will be disabled if NTP
    # is enabled. Do you wish to continue? [y/N]" - Send-CimcConfirm answers 'y'.
    Send-CimcConfirm -Port $Port -Command 'set enabled yes' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-CimcConfirm -Port $Port -Command 'commit' -TimeoutSec 30 -InterDelayMs $delayMs | Out-Null

    # Verify NTP is actually enabled before we try to load server addresses.
    # CIMC prints this as "Enabled: yes" under "NTP Service Settings:", not on
    # one line that starts with "NTP".
    $ntpStatus = Send-Command -Port $Port -Command 'show detail' `
        -ExpectPatterns @('#\s*$') -TimeoutSec 15 -InterDelayMs $delayMs
    if ($ntpStatus -match '(?im)Enabled:\s*(yes|enabled|true)\b') {
        Write-Log 'NTP service confirmed enabled.'
        if ($ntpStatus -match '(?im)Status:\s*unsynchron') {
            Write-Log 'NTP has not synchronised yet. That is normal until the servers answer.'
        }
    } else {
        Write-Log -Level WARN ("NTP did not report as enabled after commit; continuing anyway. show detail output:`n" + $ntpStatus)
    }

    Write-Log 'Loading NTP server slots (commit #2).'
    $slots = @('server-1','server-2','server-3','server-4')
    for ($i = 0; $i -lt $slots.Count; $i++) {
        if ($i -lt $ntp.Count) {
            Send-CimcConfirm -Port $Port -Command ("set {0} {1}" -f $slots[$i], $ntp[$i]) -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        } else {
            Send-CimcConfirm -Port $Port -Command ("set {0} ''" -f $slots[$i]) -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        }
    }

    Send-CimcConfirm -Port $Port -Command 'commit' -TimeoutSec 30 -InterDelayMs $delayMs | Out-Null

    # Read-back so the log captures the final NTP state for forensics.
    $finalNtp = Send-Command -Port $Port -Command 'show detail' `
        -ExpectPatterns @('#\s*$') -TimeoutSec 15 -InterDelayMs $delayMs
    Write-Log ("Post-commit NTP state:`n" + $finalNtp)

    if (-not [string]::IsNullOrWhiteSpace($Config.site.timezone)) {
        try {
            Set-CimcTimezone -Port $Port -Name ([string]$Config.site.timezone) -TimeoutSec $cmdTO -InterDelayMs $delayMs
        }
        catch {
            Write-Log -Level WARN "Timezone step did not finish: $($_.Exception.Message). Set it in the CIMC UI (Admin > Timezone)."
        }
    }
    Write-Log 'NTP configured.'
}

function Get-CimcTimezoneSteps {
    # timezone-select is a menu. These labels are the exact lines CIMC prints
    # for the Olson names this config uses. The first label that appears wins.
    param([Parameter(Mandatory)][string]$Name)
    switch ($Name) {
        'America/Chicago'     { ,@('Americas'); ,@('United States'); ,@('Central Time', 'Central (most areas)', 'Central Time (most areas)') }
        'America/New_York'    { ,@('Americas'); ,@('United States'); ,@('Eastern Time', 'Eastern (most areas)', 'Eastern Time (most areas)') }
        'America/Denver'      { ,@('Americas'); ,@('United States'); ,@('Mountain Time', 'Mountain (most areas)') }
        'America/Los_Angeles' { ,@('Americas'); ,@('United States'); ,@('Pacific Time', 'Pacific') }
        'America/Phoenix'     { ,@('Americas'); ,@('United States'); ,@('Mountain Standard Time - Arizona (except Navajo)', 'MST - AZ (except Navajo)', 'Mountain Standard - AZ (except Navajo)') }
        'America/Anchorage'   { ,@('Americas'); ,@('United States'); ,@('Alaska Time', 'Alaska (most areas)') }
        'Pacific/Honolulu'    { ,@('Americas'); ,@('United States'); ,@('Hawaii') }
        'Europe/London'       { ,@('Europe'); ,@('United Kingdom', 'Britain (UK)', 'Britain') }
        'UTC'                 { ,@('UTC', 'Etc') }
    }
}

function Exit-CimcTimezoneMenu {
    # Ctrl-C does not return this firmware to the CLI prompt. Pick the first
    # entry until the confirm question, accept it, then answer n so tzselect
    # exits without saving. The serial session stays usable for the next step.
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [string]$Menu,
        [int]$TimeoutSec = 30,
        [int]$InterDelayMs = 250
    )
    $wait = @('(?m)#\?\s*$', '(?i)Continue\?', '(?i)above information OK', '#\s*$')
    for ($n = 0; $n -lt 6; $n++) {
        if ($Menu -match '(?i)Continue\?') {
            Send-Command -Port $Port -Command 'n' -ExpectPatterns @('#\s*$', '(?m)#\?\s*$') -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs | Out-Null
            break
        }
        if ($Menu -match '(?i)above information OK') {
            $Menu = Send-Command -Port $Port -Command '1' -ExpectPatterns $wait -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs
            continue
        }
        if ($Menu -match '(?m)#\?\s*$') {
            $Menu = Send-Command -Port $Port -Command '1' -ExpectPatterns $wait -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs
            continue
        }
        break
    }
    Sync-CimcPrompt -Port $Port | Out-Null
}

function Set-CimcTimezone {
    # CIMC 4.x/6.x rejects "set timezone" and "set-timezone". The working
    # command is the interactive timezone-select menu under scope cimc.
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = 20,
        [int]$InterDelayMs = 250
    )
    $steps = @(Get-CimcTimezoneSteps -Name $Name)
    if ($steps.Count -eq 0) {
        Write-Log -Level WARN "Timezone '$Name' has no timezone-select path. Set it in the CIMC UI (Admin > Timezone)."
        return
    }

    Write-Log "Setting timezone to $Name."
    Send-Command -Port $Port -Command 'top' -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs | Out-Null
    Send-Command -Port $Port -Command 'scope cimc' -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs | Out-Null
    # Wait for the menu prompt (#?). A CLI prompt ending in '#' arrives before
    # the region list on some firmware and used to cut the read off early.
    $menuWait = @('(?m)#\?\s*$', '(?i)Continue\?', '(?i)above information OK')
    $menuTimeout = [Math]::Max($TimeoutSec, 45)
    $menu = Send-Command -Port $Port -Command 'timezone-select' `
        -ExpectPatterns $menuWait -TimeoutSec $menuTimeout -InterDelayMs $InterDelayMs
    if ($menu -notmatch '(?m)#\?\s*$') {
        Write-Log -Level WARN "CIMC did not open timezone-select for '$Name'. Set it in the CIMC UI (Admin > Timezone)."
        return
    }

    foreach ($labels in $steps) {
        if ($menu -match '(?i)above information OK') { break }
        $choice = $null
        $wanted = ''
        foreach ($label in @($labels)) {
            foreach ($hit in [regex]::Matches($menu, '(?m)^\s*(\d+)\)\s+(.+?)\s*$')) {
                if ($hit.Groups[2].Value -eq $label) {
                    $choice = $hit.Groups[1].Value
                    $wanted = $label
                    break
                }
            }
            if ($choice) { break }
        }
        if (-not $choice) {
            $shown = @([regex]::Matches($menu, '(?m)^\s*\d+\).*$') | ForEach-Object { $_.Value.Trim() }) -join '; '
            if ($shown.Length -gt 500) { $shown = $shown.Substring(0, 500) }
            Write-Log -Level WARN "Timezone menu has no entry for '$($labels -join "' or '")' while setting '$Name'. Menu was: $shown"
            try { Exit-CimcTimezoneMenu -Port $Port -Menu $menu -TimeoutSec $menuTimeout -InterDelayMs $InterDelayMs }
            catch { Write-Log -Level WARN "Could not leave the timezone menu: $($_.Exception.Message)" }
            return
        }
        Write-Log "Timezone menu: $choice) $wanted"
        $menu = Send-Command -Port $Port -Command $choice `
            -ExpectPatterns $menuWait -TimeoutSec $menuTimeout -InterDelayMs $InterDelayMs
    }

    if ($menu -match '(?i)above information OK') {
        $menu = Send-Command -Port $Port -Command '1' `
            -ExpectPatterns @('(?i)Continue\?', '#\s*$') `
            -TimeoutSec $menuTimeout -InterDelayMs $InterDelayMs
    }
    if ($menu -match '(?i)Continue\?') {
        $menu = Send-Command -Port $Port -Command 'y' `
            -ExpectPatterns @('#\s*$') -TimeoutSec $menuTimeout -InterDelayMs $InterDelayMs
    }
    if ($menu -match '(?i)Timezone has been updated') {
        Write-Log "Timezone set to $Name."
    } else {
        Write-Log -Level WARN "CIMC did not confirm timezone '$Name'. Check Admin > Timezone in the CIMC UI."
        if ($menu -notmatch '#\s*$') {
            try { Exit-CimcTimezoneMenu -Port $Port -Menu $menu -TimeoutSec $menuTimeout -InterDelayMs $InterDelayMs }
            catch { Write-Log -Level WARN "Could not leave the timezone menu: $($_.Exception.Message)" }
        }
    }
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

    # 6.0 enables the connector from "scope device-connector" or "scope cloud".
    # On 4.3, "scope cimc / scope device-connector" is the firmware-update scope:
    # "set enabled" is rejected there, and a commit with nothing staged hangs
    # the serial CLI. Try each scope, and commit only after a set is accepted.
    $paths = @(
        ,@('scope device-connector')
        ,@('scope cloud')
        ,@('scope cimc', 'scope cloud')
        ,@('scope cimc', 'scope device-connector')
    )
    $configured = $false
    foreach ($path in $paths) {
        Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        $resp = ''
        $rejected = $false
        foreach ($cmd in $path) {
            $resp = Send-Command -Port $Port -Command $cmd `
                -ExpectPatterns @('#\s*$', '(?i)invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs
            if ($resp -match '(?i)invalid command|invalid scope|unrecognized') {
                $rejected = $true
                break
            }
        }
        if ($rejected -or $resp -notmatch '(?i)/(device-connector|cloud)\s*#') { continue }

        $detail = ''
        try {
            $detail = Send-Command -Port $Port -Command 'show detail' `
                -ExpectPatterns @('#\s*$') -TimeoutSec 15 -InterDelayMs $delayMs
        }
        catch {
            Write-Log -Level WARN "Device Connector 'show detail' did not return: $($_.Exception.Message)"
            Restore-CimcCli -Port $Port | Out-Null
            continue
        }
        if ($detail -match '(?i)Enabled\s*:\s*yes') {
            Write-Log 'Device Connector is already enabled.'
            Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
            return
        }
        if ($detail -match '(?i)Update Stage|DC FW Version') {
            Write-Log "Scope '$(($path -join ' / '))' updates connector firmware. Leaving it without commit."
            continue
        }

        $enable = ''
        try {
            $enable = Send-CimcConfirm -Port $Port -Command 'set enabled yes' -TimeoutSec 15 -InterDelayMs $delayMs
        }
        catch {
            Write-Log -Level WARN "Device Connector 'set enabled' did not return: $($_.Exception.Message)"
            Restore-CimcCli -Port $Port | Out-Null
            continue
        }
        if ($enable -match '(?i)invalid command|unrecognized') {
            Write-Log "Scope '$(($path -join ' / '))' rejected 'set enabled'. Leaving it without commit."
            continue
        }
        if ($enable -notmatch '\*#') {
            Write-Log 'Device Connector set did not stage a change. Not committing.'
            continue
        }
        $configured = $true
        Send-CimcBestEffort -Port $Port -Command 'set read-only-mode no'        -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        Send-CimcBestEffort -Port $Port -Command 'set tunneled-kvm-enabled yes' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        Send-CimcBestEffort -Port $Port -Command 'set auto-update-enabled yes'  -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        if ($Config.intersight.proxyHost) {
            Send-CimcBestEffort -Port $Port -Command 'set proxy-enabled yes' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
            Send-CimcBestEffort -Port $Port -Command ("set proxy-host {0}" -f $Config.intersight.proxyHost) -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
            if ($Config.intersight.proxyPort) {
                Send-CimcBestEffort -Port $Port -Command ("set proxy-port {0}" -f [int]$Config.intersight.proxyPort) -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
            }
        }
        try {
            Send-CimcConfirm -Port $Port -Command 'commit' -TimeoutSec 30 -InterDelayMs $delayMs | Out-Null
        }
        catch {
            Write-Log -Level WARN "Device Connector commit did not confirm: $($_.Exception.Message)"
        }
        break
    }
    if (-not $configured) {
        Write-Log -Level WARN 'Could not enable the Device Connector from the CLI on this firmware. Enable it in the CIMC UI (Admin > Device Connector) before claiming in Intersight.'
        Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        return
    }

    # Report the resulting state so the operator knows whether the Device
    # Connector still needs enabling by hand before claiming in Intersight.
    $state = Send-CimcBestEffort -Port $Port -Command 'show detail' -TimeoutSec $cmdTO -InterDelayMs $delayMs
    if ($state -match '(?i)Enabled\s*:\s*yes') {
        Write-Log 'Intersight Device Connector reports Enabled: yes.'
    }
    else {
        Write-Log -Level WARN 'Could not confirm the Device Connector is enabled. Check Admin > Device Connector in the CIMC UI before claiming in Intersight.'
    }
}

# -------------------- Firmware upgrade (Host Upgrade Utility) --------------------
# CIMC reads the ISO over its management IP, not the serial cable. The script
# serves the ISO over HTTP. CIMC then mounts it and runs the HUU update.
# map-www is only the fallback when that job cannot be started.

function Get-LocalIPv4Addresses {
    # All usable local IPv4 addresses (skips loopback and link-local).
    $list = @()
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $ip = $ua.Address.ToString()
                if ($ip -like '127.*' -or $ip -like '169.254.*') { continue }
                $list += $ip
            }
        }
    } catch {}
    return $list
}

function Get-IPv4InterfaceName {
    param([Parameter(Mandatory)][string]$Address)
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
                if ($ua.Address.ToString() -eq $Address) { return $ni.Name }
            }
        }
    } catch {}
    return $null
}

function Test-IpInSubnet {
    # True if $A and $B are in the same IPv4 subnet under $Mask.
    param([string]$A, [string]$B, [string]$Mask)
    try {
        $ab = ([System.Net.IPAddress]::Parse($A)).GetAddressBytes()
        $bb = ([System.Net.IPAddress]::Parse($B)).GetAddressBytes()
        $mb = ([System.Net.IPAddress]::Parse($Mask)).GetAddressBytes()
        for ($i = 0; $i -lt 4; $i++) {
            if ((($ab[$i] -band $mb[$i]) -ne ($bb[$i] -band $mb[$i]))) { return $false }
        }
        return $true
    } catch { return $false }
}

function Get-ServeHostAddress {
    # Determine the laptop IPv4 the CIMC should use to reach our ISO server.
    #   1) explicit override wins;
    #   2) otherwise prefer a local IPv4 that is IN THE SAME SUBNET as the CIMC
    #      (e.g. the Ethernet cabled directly to the CIMC mgmt port) - this is
    #      the address the CIMC can actually reach;
    #   3) fall back to the default-route interface (may be Wi-Fi/corp and NOT
    #      reachable by the CIMC - warn if we land here).
    param([string]$Override, [string]$TargetIp, [string]$SubnetMask)
    if ($Override) { return $Override }

    if ($TargetIp -and $SubnetMask) {
        foreach ($addr in (Get-LocalIPv4Addresses)) {
            if ($addr -eq $TargetIp) { continue }
            if (Test-IpInSubnet -A $addr -B $TargetIp -Mask $SubnetMask) {
                Write-Log "Serve host $addr is on the CIMC subnet ($TargetIp/$SubnetMask); using it."
                return $addr
            }
        }
        Write-Log -Level WARN "No local IP found on the CIMC subnet ($TargetIp/$SubnetMask). Make sure your Ethernet to the CIMC has a static IP in that subnet, or set firmware.serveHost. Falling back to the default-route address."
    }

    try {
        $s = [System.Net.Sockets.Socket]::new(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp)
        $s.Connect('8.8.8.8', 65530)
        $ip = ([System.Net.IPEndPoint]$s.LocalEndPoint).Address.ToString()
        $s.Close()
        return $ip
    } catch { return $null }
}

function Resolve-PythonCommand {
    # Prefer a real interpreter. On Windows, "python" and "python3" often resolve
    # to the Microsoft Store app-execution alias under WindowsApps. That stub
    # starts and exits immediately, which looks like a failed HTTP server.
    $stubs = @()
    foreach ($name in @('py','python','python3')) {
        $cmds = @(Get-Command $name -All -ErrorAction SilentlyContinue)
        foreach ($cmd in $cmds) {
            $src = [string]$cmd.Source
            if (-not $src) { continue }
            if ($src -match '(?i)\\WindowsApps\\python') {
                $stubs += $src
                continue
            }
            return $cmd
        }
    }
    if ($stubs.Count -gt 0) {
        throw ("Python on PATH is only the Windows Store shortcut ({0}), which exits immediately and cannot serve the ISO. Install Python 3 from https://www.python.org/downloads/ and enable 'Add python.exe to PATH', then open a new PowerShell window. You can also turn off the python.exe and python3.exe App execution aliases under Settings > Apps > Advanced app settings." -f $stubs[0])
    }
    throw "Python 3 is required to serve the ISO locally. Install it from https://www.python.org/downloads/ or set firmware.transport to 'url' and provide firmware.shareUrl."
}

function Test-IsWindowsAdmin {
    if ($env:OS -ne 'Windows_NT') { return $false }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Add-IsoHttpFirewallRule {
    # Best-effort. A non-admin shell cannot change the firewall. Connecting to
    # the laptop's own Ethernet IP is an inbound connection, so Windows can
    # block http://<ethernet-ip>:8000 while http://127.0.0.1:8000 still works.
    param(
        [Parameter(Mandatory)][int]$ListenPort,
        [string]$Program
    )
    if ($env:OS -ne 'Windows_NT') { return }
    $name = "UCS CIMC ISO HTTP $ListenPort"
    & netsh advfirewall firewall delete rule name="$name" | Out-Null
    $out = & netsh advfirewall firewall add rule name="$name" dir=in action=allow protocol=TCP localport=$ListenPort profile=any enable=yes 2>&1 | Out-String
    if ($Program) {
        $progName = "$name python"
        & netsh advfirewall firewall delete rule name="$progName" | Out-Null
        $progOut = & netsh advfirewall firewall add rule name="$progName" dir=in action=allow program="$Program" protocol=TCP localport=$ListenPort profile=any enable=yes 2>&1 | Out-String
        $out = ($out + ' ' + $progOut).Trim()
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Windows Firewall allows inbound TCP $ListenPort."
    } else {
        $who = if (Test-IsWindowsAdmin) { 'The firewall command failed.' } else { 'This window is not running as Administrator.' }
        Write-Log -Level WARN "Could not add a Windows Firewall allow rule for TCP ${ListenPort}. $who $out"
    }
}

function Test-IsoHttpReachable {
    # Returns $true when the URL answers HTTP 200 or 206. A full GET of the
    # ISO would download several gigabytes, so -Range reads one byte.
    param(
        [Parameter(Mandatory)][string]$Url,
        [switch]$Range
    )
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.Timeout = 8000
    $req.ReadWriteTimeout = 8000
    $req.AllowAutoRedirect = $false
    $req.KeepAlive = $false
    # Wi-Fi often has a proxy. A browser will send http://<ethernet-ip>:8000
    # to that proxy, which cannot reach the CIMC subnet. Bypass it here.
    try { $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy() } catch {
        $req.Proxy = New-Object System.Net.WebProxy
    }
    if ($Range) { $req.AddRange(0, 15) }
    try {
        $resp = $req.GetResponse()
        try {
            $code = [int]$resp.StatusCode
            Write-Log "Local check of $Url returned HTTP $code."
            if ($Range) {
                if ($code -ne 206) {
                    Write-Log -Level WARN "The server ignored the Range request. CIMC vMedia requires HTTP 206 Partial Content."
                    return $false
                }
                $contentRange = [string]$resp.Headers['Content-Range']
                $acceptRanges = [string]$resp.Headers['Accept-Ranges']
                if ($contentRange -notmatch '^bytes\s+0-15/\d+$' -or $acceptRanges -notmatch '(?i)\bbytes\b') {
                    Write-Log -Level WARN "The HTTP 206 response is missing valid byte-range headers (Content-Range='$contentRange', Accept-Ranges='$acceptRanges')."
                    return $false
                }
                return $true
            }
            return ($code -eq 200)
        } finally {
            $resp.Close()
        }
    } catch [System.Net.WebException] {
        $failed = $_.Exception.Response
        if ($failed) {
            $code = [int]$failed.StatusCode
            $failed.Close()
            Write-Log -Level WARN "Local check of $Url returned HTTP $code."
        } else {
            Write-Log -Level WARN "Local check of $Url failed: $($_.Exception.Message)"
        }
        return $false
    } catch {
        Write-Log -Level WARN "Local check of $Url failed: $($_.Exception.Message)"
        return $false
    }
}

function Start-IsoHttpServer {
    # Serve $Folder over HTTP on $BindAddress:$ListenPort.
    # The parameter is NOT named Port: PowerShell variable names are
    # case-insensitive, so $Port would collide with the serial-port object and
    # the HTTP listener would be handed a SerialPort instead of an integer.
    # Returns the running Process object (kept alive until the upgrade finishes).
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][int]$ListenPort,
        [Parameter(Mandatory)][string]$BindAddress
    )
    if (-not (Test-Path -LiteralPath $Folder)) {
        throw "Firmware folder not found: '$Folder'."
    }
    $python = Resolve-PythonCommand
    $full = (Resolve-Path -LiteralPath $Folder).Path
    # CIMC joins the share and the filename with its own slash, so the request
    # path is sometimes "//file.iso". Python on Windows treats a path that
    # still starts with "//" as a UNC path and returns 404. Collapse the extra
    # slash before mapping the URL onto the folder.
    $helper = Join-Path ([System.IO.Path]::GetTempPath()) ("cimc-iso-http-{0}.py" -f $PID)
    $script:IsoHelperPath = $helper
    Set-Content -LiteralPath $helper -Encoding ASCII -Value @'
import os
import sys
import posixpath
import urllib.parse
try:
    from http.server import ThreadingHTTPServer as HttpServer, SimpleHTTPRequestHandler
except ImportError:
    from socketserver import ThreadingMixIn
    from http.server import HTTPServer, SimpleHTTPRequestHandler
    class HttpServer(ThreadingMixIn, HTTPServer):
        daemon_threads = True

class IsoHandler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *args, **kwargs):
        self.range_to_send = None
        self.sent_accept_ranges = False
        super().__init__(*args, **kwargs)

    def translate_path(self, path):
        path = urllib.parse.urlsplit(path).path
        path = urllib.parse.unquote(path)
        path = posixpath.normpath(path)
        while "//" in path:
            path = path.replace("//", "/")
        words = [w for w in path.split("/") if w not in ("", ".", "..")]
        out = os.getcwd()
        for word in words:
            out = os.path.join(out, word)
        return out

    def send_header(self, keyword, value):
        if keyword.lower() == "accept-ranges":
            self.sent_accept_ranges = True
        super().send_header(keyword, value)

    def end_headers(self):
        if not self.sent_accept_ranges:
            self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def send_head(self):
        self.range_to_send = None
        self.sent_accept_ranges = False
        raw_range = self.headers.get("Range")
        if not raw_range:
            return super().send_head()

        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            return super().send_head()

        try:
            file_size = os.path.getsize(path)
            unit, separator, value = raw_range.strip().partition("=")
            if unit.lower() != "bytes" or not separator or "," in value:
                raise ValueError("unsupported range")
            first, dash, last = value.partition("-")
            if not dash:
                raise ValueError("invalid range")
            if first:
                start = int(first)
                end = int(last) if last else file_size - 1
            else:
                suffix_length = int(last)
                if suffix_length <= 0:
                    raise ValueError("invalid suffix range")
                start = max(0, file_size - suffix_length)
                end = file_size - 1
            if start < 0 or start >= file_size or end < start:
                raise ValueError("range outside file")
            end = min(end, file_size - 1)
            source = open(path, "rb")
        except (OSError, ValueError):
            self.send_response(416)
            self.send_header("Content-Range", "bytes */%d" % (
                os.path.getsize(path) if os.path.isfile(path) else 0
            ))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None

        self.range_to_send = (start, end)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", "bytes %d-%d/%d" % (
            start, end, file_size
        ))
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Last-Modified", self.date_time_string(
            os.path.getmtime(path)
        ))
        self.end_headers()
        return source

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stderr.flush()

    def copyfile(self, source, outputfile):
        try:
            if self.range_to_send is None:
                super().copyfile(source, outputfile)
                return
            start, end = self.range_to_send
            source.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = source.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                outputfile.write(chunk)
                remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

bind = sys.argv[1]
port = int(sys.argv[2])
os.chdir(sys.argv[3])
HttpServer.allow_reuse_address = True
server = HttpServer((bind, port), IsoHandler)
sys.stderr.write("listening on %s:%s\n" % (bind, port))
sys.stderr.flush()
server.serve_forever()
'@
    $pyArgs = if ([System.IO.Path]::GetFileName($python.Source) -ieq 'py.exe') {
        "-3 `"$helper`" $BindAddress $ListenPort `"$full`""
    } else {
        "`"$helper`" $BindAddress $ListenPort `"$full`""
    }
    Write-Log "Starting local HTTP server: folder='$full' bind=${BindAddress}:${ListenPort} (python: $($python.Source))"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $python.Source
    $psi.Arguments              = $pyArgs
    $psi.WorkingDirectory       = $full
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $logPath = $script:SessionLog
    # CIMC reads the ISO in thousands of byte-range requests. Keep the first
    # request from each client, every error, and one summary a minute.
    $script:HttpLogState = [hashtable]::Synchronized(@{
        LogPath = $logPath
        Hits    = 0
        Last    = [datetime]::UtcNow
        Seen    = '|'
    })
    foreach ($evt in @('OutputDataReceived','ErrorDataReceived')) {
        Register-ObjectEvent -InputObject $proc -EventName $evt -MessageData $script:HttpLogState `
            -SourceIdentifier ("CimcHttp{0}{1}" -f $evt, $proc.Id) -Action {
                $text = $EventArgs.Data
                if (-not $text) { return }
                $st = $Event.MessageData
                $level = 'INFO'
                $show = $false
                if ($text -match '^(\S+) - "[A-Z]+ [^"]*" (\d+)') {
                    $ip = $Matches[1]
                    $code = [int]$Matches[2]
                    $st.Hits = [int]$st.Hits + 1
                    if ($code -ge 400) { $level = 'WARN'; $show = $true }
                    elseif ($st.Seen -notlike "*|$ip|*") {
                        $st.Seen = $st.Seen + $ip + '|'
                        $show = $true
                    }
                    elseif (((Get-Date).ToUniversalTime() - [datetime]$st.Last).TotalSeconds -ge 60) {
                        $st.Last = [datetime]::UtcNow
                        $text = "$($st.Hits) requests so far. Latest: $text"
                        $show = $true
                    }
                } else {
                    $show = $true
                    if ($text -match '(?i)error|traceback|exception') { $level = 'WARN' }
                }
                if (-not $show) { return }
                $line = '{0} [{1}] HTTP: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $level, $text
                Add-Content -LiteralPath $st.LogPath -Value $line
                Write-Host $line
            } | Out-Null
    }
    try { $proc.BeginOutputReadLine() } catch {}
    try { $proc.BeginErrorReadLine() } catch {}
    Start-Sleep -Seconds 1
    if ($proc.HasExited) {
        $detail = ''
        try { $detail = (($proc.StandardError.ReadToEnd() + ' ' + $proc.StandardOutput.ReadToEnd()).Trim()) } catch {}
        Get-EventSubscriber -ErrorAction SilentlyContinue |
            Where-Object { $_.SourceIdentifier -like ("CimcHttp*{0}" -f $proc.Id) } |
            ForEach-Object { Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue }
        if (-not $detail) {
            $detail = "Check that Python 3 is really installed (not the Windows Store alias), that $BindAddress is an address on this laptop, and that TCP port $ListenPort is free."
        }
        Stop-IsoHttpServer -Proc $proc
        throw "Local HTTP server exited immediately (exit code $($proc.ExitCode)). $detail"
    }
    return $proc
}

function Stop-IsoHttpServer {
    param([System.Diagnostics.Process]$Proc)
    if ($Proc) {
        Get-EventSubscriber -ErrorAction SilentlyContinue |
            Where-Object { $_.SourceIdentifier -like ("CimcHttp*{0}" -f $Proc.Id) } |
            ForEach-Object { Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue }
    }
    if ($Proc -and -not $Proc.HasExited) {
        try { $Proc.Kill() } catch {}
        try { $Proc.WaitForExit(3000) | Out-Null } catch {}
        $hits = 0
        if ($script:HttpLogState) { $hits = [int]$script:HttpLogState.Hits }
        Write-Log "Local HTTP server stopped ($hits requests)."
    }
    if ($script:IsoHelperPath -and (Test-Path -LiteralPath $script:IsoHelperPath)) {
        Remove-Item -LiteralPath $script:IsoHelperPath -Force -ErrorAction SilentlyContinue
        $script:IsoHelperPath = $null
    }
}

function Get-CimcPromptKind {
    # A trailing '#' is not proof the CLI is ready. map-www prints
    # "Password:" and then reprints "hostname /vmedia #" on the next line.
    # The credential question has to win, or the next command is typed into
    # the password field and the mapping is abandoned.
    param([string]$Text)
    $flat = $Text -replace "`r", ''
    if ($flat -match "(?i)enter 'yes' or 'no'") { return 'save' }
    $pass = [regex]::Matches($flat, '(?i)password\s*:')
    $user = [regex]::Matches($flat, '(?i)user\s*name\s*:')
    $passAt = if ($pass.Count -gt 0) { $pass[$pass.Count - 1].Index } else { -1 }
    $userAt = if ($user.Count -gt 0) { $user[$user.Count - 1].Index } else { -1 }
    if ($passAt -ge 0 -and $passAt -ge $userAt) { return 'password' }
    if ($userAt -ge 0) { return 'username' }
    # A reprinted "hostname #" is often followed by "[y/N]". The question has
    # to win, or the next command is typed in as the answer.
    $confirm = [regex]::Matches($flat, $script:RxConfirm)
    $hashes = [regex]::Matches($flat, '#')
    $confirmAt = if ($confirm.Count -gt 0) { $confirm[$confirm.Count - 1].Index } else { -1 }
    $hashAt = if ($hashes.Count -gt 0) { $hashes[$hashes.Count - 1].Index } else { -1 }
    if ($confirmAt -ge 0 -and $confirmAt -gt $hashAt) { return 'confirm' }
    if ($flat -match '#\s*$') { return 'cli' }
    return ''
}

function Write-CimcTail {
    param([string]$Text)
    $flat = ($Text -replace "[`r`n]+", ' | ').Trim()
    if ($flat.Length -gt 240) { $flat = $flat.Substring($flat.Length - 240) }
    if ($flat) { Write-Log "CIMC said: $flat" }
}

function Read-CimcSettle {
    # Read until the console has been quiet. map-www reprints the '#' prompt and
    # THEN asks for a password. Returning on the first '#' types the next
    # command into that password field, so the ISO mapping is saved but never
    # mounts. A credential prompt is accepted as soon as it is quiet; a CLI
    # prompt is accepted only after QuietMs with no further bytes.
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [int]$TimeoutSec = 90,
        # A '#' prompt is accepted only after this long with no more bytes.
        # map-www reprints '#' and then asks for a password a few seconds later.
        [int]$QuietMs = 8000,
        # Username/password prompts are accepted quickly once they have arrived.
        [int]$PromptQuietMs = 400
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastRx = [System.Diagnostics.Stopwatch]::StartNew()
    $buffer = [System.Text.StringBuilder]::new()
    $saw = $false
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $got = $false
        try {
            if ($Port.BytesToRead -gt 0) {
                $chunk = $Port.ReadExisting()
                if ($chunk) {
                    [void]$buffer.Append($chunk)
                    Write-Log -Level RX -Message ($chunk -replace "[`r`n]+", ' | ')
                    $got = $true
                    $saw = $true
                }
            }
        } catch {}
        if ($got) { $lastRx.Restart() }
        else { Start-Sleep -Milliseconds 100 }

        if (-not $saw) { continue }
        $kind = Get-CimcPromptKind -Text $buffer.ToString()
        $quiet = $lastRx.ElapsedMilliseconds
        if (($kind -eq 'username' -or $kind -eq 'password' -or $kind -eq 'save' -or $kind -eq 'confirm') -and $quiet -ge $PromptQuietMs) {
            return $buffer.ToString()
        }
        if ($kind -eq 'cli' -and $quiet -ge $QuietMs) { return $buffer.ToString() }
    }
    Write-CimcTail -Text $buffer.ToString()
    $tail = $buffer.ToString()
    if ($tail.Length -gt 200) { $tail = $tail.Substring($tail.Length - 200) }
    throw "Timeout waiting for a settled CIMC prompt. Last 200 chars: '$tail'"
}

function Set-CimcVmediaMap {
    # Map the ISO into a CIMC vMedia volume. Do not query the mapping status;
    # that command stops answering on this CIMC.
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Volume,
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$IsoFile,
        [string]$User,
        [string]$Pass
    )
    $cmdTO   = [int]$Config.behavior.commandTimeoutSec
    $delayMs = [int]$Config.behavior.interCommandDelayMs

    Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'scope vmedia' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null

    # Remove any pre-existing volume with the same name so re-runs are clean.
    # CIMC does not use the usual [y/N] prompt here. It asks:
    #   Save mapping? Enter 'yes' or 'no' to confirm (CTRL-C to cancel) -->
    # 'no' drops the saved mapping so map-www can recreate the volume.
    $unmap = Send-Command -Port $Port -Command "unmap $Volume" `
        -ExpectPatterns @($script:RxCli, "(?i)enter 'yes' or 'no'", '(?i)does not exist', '(?i)not found', '(?i)invalid') `
        -TimeoutSec $cmdTO -InterDelayMs $delayMs
    if ($unmap -match "(?i)enter 'yes' or 'no'" -and $unmap -notmatch $script:RxCli) {
        Write-Log 'Unmap asked whether to save the mapping; answering "no" so the old volume is removed.'
        Send-Command -Port $Port -Command 'no' `
            -ExpectPatterns @($script:RxCli, '(?i)error', '(?i)invalid') `
            -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    }

    # The space is required. map-www takes the share and the filename as two
    # fields (Cisco IMC 6.0: map-www volume remote-share remote-file). CIMC
    # joins them into one URL with no space: http://host:8000/ + file.iso.
    Write-Log "Mapping vMedia volume '$Volume'. Share '$BaseUrl' and file '$IsoFile' join as ${BaseUrl}${IsoFile}."
    $mapCmd = "map-www {0} {1} {2}" -f $Volume, $BaseUrl, $IsoFile
    Write-Log -Level TX -Message "-> $mapCmd"
    $Port.WriteLine($mapCmd)
    Start-Sleep -Milliseconds $delayMs
    $resp = Read-CimcSettle -Port $Port -TimeoutSec $cmdTO -QuietMs 8000
    Write-CimcTail -Text $resp

    # Python's HTTP server has no login. Leave the username and password blank
    # unless firmware.shareUser / firmware.sharePassword are set. A manual
    # mapping on this CIMC accepts those empty fields. Answer whichever prompts
    # appear, and stop when the CLI prompt is back.
    $guard = 6
    while ($guard-- -gt 0) {
        $kind = Get-CimcPromptKind -Text $resp
        if ($kind -eq 'password') {
            Write-Log 'map-www password prompt; sending configured password or a blank Enter.'
            $shownPass = if ([string]::IsNullOrEmpty($Pass)) { '<blank>' } else { '<redacted>' }
            Write-Log -Level TX -Message "-> $shownPass"
            $Port.WriteLine([string]$Pass)
        }
        elseif ($kind -eq 'username') {
            $sendUser = [string]$User
            if ([string]::IsNullOrEmpty($sendUser)) {
                Write-Log 'map-www username prompt; leaving it blank.'
                Write-Log -Level TX -Message '-> <blank>'
            } else {
                Write-Log 'map-www username prompt; sending configured username.'
                Write-Log -Level TX -Message "-> $sendUser"
            }
            $Port.WriteLine($sendUser)
        }
        elseif ($kind -eq 'confirm') {
            Write-Log 'map-www confirmation prompt; sending "y".'
            Write-Log -Level TX -Message '-> y'
            $Port.WriteLine('y')
        }
        elseif ($kind -eq 'cli') {
            Write-Log 'map-www returned to the CLI prompt.'
            break
        }
        else { break }
        Start-Sleep -Milliseconds $delayMs
        # CIMC can take well over a minute to print the prompt again while it
        # opens the ISO. The previous 90s limit expired as the hostname was
        # still being written ("moa" of "moab-..."), which aborted the mount.
        try {
            $resp = Read-CimcSettle -Port $Port -TimeoutSec 180 -QuietMs 2000
        }
        catch {
            Write-Log -Level WARN "map-www did not finish printing the prompt: $($_.Exception.Message). The mapping can still be active. Leaving the ISO server running."
            return "map-www accepted $Volume"
        }
        Write-CimcTail -Text $resp
    }

    if ((Get-CimcPromptKind -Text $resp) -ne 'cli') {
        throw "CIMC did not return to a prompt after map-www. It may be unable to reach $BaseUrl from the CIMC management IP. Allow Python through Windows Firewall on the laptop Ethernet NIC that faces the CIMC."
    }

    # Do not run "show mappings". On this CIMC it probes the ISO and then never
    # returns a prompt, even when the CIMC UI already shows the map.
    $serveIp = ''
    if ($BaseUrl -match '^https?://([^/:]+)') { $serveIp = $Matches[1] }
    $cimcClient = Wait-CimcHttpClient -LogPath $script:SessionLog -LaptopAddresses @('127.0.0.1', $serveIp) -TimeoutSec 3
    if ($cimcClient) {
        Write-Log "CIMC address $($cimcClient -join ', ') reached the ISO. Mapping '$Volume' is accepted; continuing without 'show mappings'."
    } else {
        Write-Log "map-www accepted volume '$Volume'. No CIMC HTTP request yet; the CIMC may open ${BaseUrl}${IsoFile} when the host boots. Continuing without 'show mappings'."
    }
    return "map-www accepted $Volume"
}

function Wait-CimcHttpClient {
    # HTTP events are written by another PowerShell runspace, so the session
    # log is the handoff. Ignore the laptop's own preflight requests.
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [string[]]$LaptopAddresses,
        [int]$TimeoutSec = 10
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $found = @{}
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (Test-Path -LiteralPath $LogPath) {
            $lines = @(Select-String -LiteralPath $LogPath -Pattern 'HTTP: (\d+\.\d+\.\d+\.\d+) -' -ErrorAction SilentlyContinue)
            foreach ($line in $lines) {
                foreach ($match in $line.Matches) {
                    $ip = $match.Groups[1].Value
                    if ($LaptopAddresses -notcontains $ip) { $found[$ip] = $true }
                }
            }
        }
        if ($found.Count -gt 0) { return @($found.Keys) }
        Start-Sleep -Milliseconds 250
    }
    return @()
}

function Get-CimcBootDeviceNames {
    # Pull device names out of "show boot-device". The table is padded, and the
    # command echo is included in the serial buffer.
    param([string]$Text)
    $names = @()
    foreach ($line in ($Text -split "[`r`n]+")) {
        $line = $line.Trim()
        if ($line -notmatch '^([A-Za-z0-9][A-Za-z0-9._-]*)\s+(VMEDIA|LOCALHDD|HDD|UEFISHELL|EFI|PXE|USB|SAN|SDCARD|SD|HTTP|HTTPS|PCHSTORAGE|ISCSI|NVME)\s+') { continue }
        $name = $Matches[1]
        if ($names -notcontains $name) { $names += $name }
    }
    return $names
}

function Set-CimcPrecisionBootDevice {
    # Create the device when it is missing, then enable it. Order is applied
    # later for every device in one rearrange-boot-device command. Cisco says
    # setting order on one device at a time does not keep the displayed order.
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][int]$TimeoutSec,
        [Parameter(Mandatory)][int]$InterDelayMs,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Type,
        [string]$Subtype
    )
    $scope = Send-Command -Port $Port -Command ("scope boot-device {0}" -f $Name) `
        -ExpectPatterns @('#\s*$', '(?i)invalid', '(?i)does not exist', '(?i)not found') `
        -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs
    if ($scope -match '(?i)invalid|does not exist|not found') {
        $created = Send-CimcConfirm -Port $Port -Command ("create-boot-device {0} {1}" -f $Name, $Type) `
            -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs
        if ($created -match '(?i)invalid') {
            Write-Log -Level WARN "Could not create boot device '$Name' of type '$Type'."
            return
        }
        Send-CimcConfirm -Port $Port -Command 'commit' -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs | Out-Null
        Send-Command -Port $Port -Command ("scope boot-device {0}" -f $Name) `
            -ExpectPatterns @('#\s*$', '(?i)invalid') -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs | Out-Null
    }
    if ($Subtype) {
        $subResp = Send-Command -Port $Port -Command ("set subtype {0}" -f $Subtype) `
            -ExpectPatterns @('#\s*$', '(?i)invalid') -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs
        if ($subResp -match '(?i)invalid') {
            Write-Log -Level WARN "Boot subtype '$Subtype' was rejected for '$Name'."
        }
    }
    Send-Command -Port $Port -Command 'set state Enabled' `
        -ExpectPatterns @('#\s*$', '(?i)invalid') -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs | Out-Null
    Send-CimcConfirm -Port $Port -Command 'commit' -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs | Out-Null
    Send-Command -Port $Port -Command 'exit' -ExpectPatterns @('#\s*$') -TimeoutSec $TimeoutSec -InterDelayMs $InterDelayMs | Out-Null
}

function Set-CimcVmediaBootOrder {
    # Precision boot order, applied in one rearrange so the list stays put:
    #   1. KVM mapped DVD
    #   2. CIMC mapped vDVD
    #   3. local boot drive
    #   4. any other configured devices
    #   5. UEFI shell
    # Used only when the automatic HUU job cannot be started.
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Fw
    )
    $cmdTO   = [int]$Config.behavior.commandTimeoutSec
    $delayMs = [int]$Config.behavior.interCommandDelayMs

    $kvmName = if ($Fw.kvmBootName)    { [string]$Fw.kvmBootName }    else { 'KvmDvd' }
    $kvmSub  = if ($Fw.kvmSubtype)     { [string]$Fw.kvmSubtype }     else { 'KVMMAPPEDDVD' }
    $dvdName = if ($Fw.dvdBootName)    { [string]$Fw.dvdBootName }    else { 'vDVD' }
    $dvdSub  = if ($Fw.vmediaSubtype)  { [string]$Fw.vmediaSubtype }  else { 'CIMCMAPPEDDVD' }
    $lunName = if ($Fw.localBootName)  { [string]$Fw.localBootName }  else { 'LocalLUN' }
    $lunType = if ($Fw.localBootType)  { [string]$Fw.localBootType }  else { 'LOCALHDD' }
    $shellName = if ($Fw.uefiShellName) { [string]$Fw.uefiShellName } else { 'UefiShell' }
    $shellType = if ($Fw.uefiShellType) { [string]$Fw.uefiShellType } else { 'UEFISHELL' }

    Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'scope bios' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null

    $existing = Send-Command -Port $Port -Command 'show boot-device' -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs
    Write-Log "Existing precision boot devices:`n$existing"

    Set-CimcPrecisionBootDevice -Port $Port -TimeoutSec $cmdTO -InterDelayMs $delayMs -Name $kvmName -Type 'VMEDIA' -Subtype $kvmSub
    Set-CimcPrecisionBootDevice -Port $Port -TimeoutSec $cmdTO -InterDelayMs $delayMs -Name $dvdName -Type 'VMEDIA' -Subtype $dvdSub
    Set-CimcPrecisionBootDevice -Port $Port -TimeoutSec $cmdTO -InterDelayMs $delayMs -Name $lunName -Type $lunType
    Set-CimcPrecisionBootDevice -Port $Port -TimeoutSec $cmdTO -InterDelayMs $delayMs -Name $shellName -Type $shellType

    $listed = Send-Command -Port $Port -Command 'show boot-device' -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs
    $known = @(Get-CimcBootDeviceNames -Text $listed)
    $preferred = @($kvmName, $dvdName, $lunName)
    $ordered = @()
    foreach ($name in ($preferred + $known)) {
        if ($name -and $name -ne $shellName -and $ordered -notcontains $name) { $ordered += $name }
    }
    $ordered += $shellName
    $pairs = @()
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $pairs += ('{0}:{1}' -f $ordered[$i], ($i + 1))
    }
    $rearrange = 'rearrange-boot-device ' + ($pairs -join ',')
    Write-Log "Setting precision boot order: $rearrange"
    $rearranged = Send-Command -Port $Port -Command $rearrange `
        -ExpectPatterns @('#\s*$', '(?i)invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs
    if ($rearranged -match '(?i)invalid') {
        Write-Log -Level WARN "rearrange-boot-device was rejected. The individual device order was not used, because CIMC does not keep that order."
    }

    $final = Send-Command -Port $Port -Command 'show boot-device' -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs
    Write-Log "Configured precision boot order:`n$final"
}

function Initialize-CimcXmlTls {
    # CIMC management HTTPS on 4.x/6.x answers TLS 1.2. TLS 1.3 is offered too
    # when this Windows build has it. The appliance certificate is self-signed,
    # so it is accepted for this process only and its properties are logged.
    if ($script:CimcXmlTlsReady) { return }
    $protocols = [System.Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([System.Net.SecurityProtocolType]) -contains 'Tls13') {
        $protocols = $protocols -bor [System.Net.SecurityProtocolType]::Tls13
    }
    [System.Net.ServicePointManager]::SecurityProtocol = $protocols
    [System.Net.ServicePointManager]::Expect100Continue = $false
    $script:CimcCertNoted = $false
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
        param($sender, $certificate, $chain, $sslPolicyErrors)
        if (-not $script:CimcCertNoted -and $certificate) {
            $script:CimcCertNoted = $true
            try {
                $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certificate
                $keyBits = ''
                try { $keyBits = [string]$x509.PublicKey.Key.KeySize } catch { $keyBits = 'unknown' }
                $sig = $x509.SignatureAlgorithm.FriendlyName
                Write-Log ("CIMC HTTPS certificate: subject='{0}' issuer='{1}' notAfter={2} signature={3} keyBits={4}." -f $x509.Subject, $x509.Issuer, $x509.NotAfter.ToString('yyyy-MM-dd'), $sig, $keyBits)
                if ($x509.NotAfter -lt (Get-Date)) {
                    Write-Log -Level WARN ("This certificate expired on {0}. It is no longer valid and will be rejected by clients that verify it. The management session continues because this is the CIMC appliance certificate." -f $x509.NotAfter.ToString('yyyy-MM-dd'))
                }
                if ($x509.NotBefore -gt (Get-Date)) {
                    Write-Log -Level WARN ("This certificate is not yet valid. Its validity period begins on {0}." -f $x509.NotBefore.ToString('yyyy-MM-dd HH:mm'))
                    Write-Log 'The CIMC clock can be ahead of this laptop until NTP synchronises. The management session continues.'
                }
                $weakRsa = ($x509.PublicKey.Oid.FriendlyName -match 'RSA' -and $keyBits -match '^\d+$' -and [int]$keyBits -lt 2048)
                $weakEc = ($x509.PublicKey.Oid.FriendlyName -match 'ECC|ECDSA' -and $keyBits -match '^\d+$' -and [int]$keyBits -lt 256)
                if ($weakRsa -or $weakEc) {
                    Write-Log -Level WARN ("The certificate's public key is cryptographically weak ({0}, {1} bits). Keys of this strength are vulnerable to factorization or discrete logarithm attacks. The certificate should be re-issued using at least an RSA 2048-bit key or an ECDSA key on a P-256 (or higher) curve." -f $x509.PublicKey.Oid.FriendlyName, $keyBits)
                }
                if ($sig -match 'md5|sha1') {
                    Write-Log -Level WARN ("The certificate is signed with the insecure algorithm '{0}'. This makes it vulnerable to collision attacks, potentially allowing for certificate forgery. It must be re-issued using a signature based on the SHA-2 family (for example, sha256WithRSAEncryption)." -f $sig)
                }
                if ($x509.Subject -eq $x509.Issuer) {
                    Write-Log 'This is a self-signed certificate. It is accepted for this CIMC management session only.'
                }
            }
            catch {
                Write-Log -Level WARN 'CIMC presented an HTTPS certificate that could not be inspected. The management session continues.'
            }
        }
        return $true
    }
    $script:CimcXmlTlsReady = $true
}

function ConvertTo-CimcXmlValue {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return [System.Security.SecurityElement]::Escape($Value)
}

function Send-CimcXmlRequest {
    param(
        [Parameter(Mandatory)][string]$CimcIp,
        [Parameter(Mandatory)][string]$Body,
        [int]$TimeoutSec = 90
    )
    Initialize-CimcXmlTls
    $uri = "https://$CimcIp/nuova"
    $req = [System.Net.HttpWebRequest]::Create($uri)
    $req.Method = 'POST'
    $req.ContentType = 'text/xml'
    $req.Accept = 'text/xml'
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.KeepAlive = $false
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $req.ContentLength = $bytes.Length
    $stream = $req.GetRequestStream()
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Close() }
    $response = $null
    try {
        $response = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        try { return $reader.ReadToEnd() } finally { $reader.Close() }
    }
    catch [System.Net.WebException] {
        $http = $_.Exception.Response
        if (-not $http) { throw }
        $reader = New-Object System.IO.StreamReader($http.GetResponseStream())
        try { return $reader.ReadToEnd() } finally { $reader.Close() }
    }
    finally {
        if ($response) { $response.Close() }
    }
}

function Connect-CimcXml {
    param([Parameter(Mandatory)][string]$CimcIp)
    $user = ConvertTo-CimcXmlValue $script:CimcUsername
    $pass = ConvertTo-CimcXmlValue $script:CimcPassword
    # The login body contains the CIMC password. It is not written to the log.
    $body = "<aaaLogin inName=`"$user`" inPassword=`"$pass`"/>"
    $text = Send-CimcXmlRequest -CimcIp $CimcIp -Body $body -TimeoutSec 60
    if ($text -match 'errorDescr="([^"]+)"' -and $text -match 'errorCode="([^"]+)"' -and $Matches[1]) {
        $why = ([regex]::Match($text, 'errorDescr="([^"]*)"')).Groups[1].Value
        throw "CIMC XML login failed: $why"
    }
    $cookie = [regex]::Match($text, 'outCookie="([^"]+)"')
    if (-not $cookie.Success) { throw 'CIMC XML login did not return a session cookie.' }
    return $cookie.Groups[1].Value
}

function Get-CimcHuuStatus {
    param(
        [Parameter(Mandatory)][string]$CimcIp,
        [Parameter(Mandatory)][string]$Cookie
    )
    $safeCookie = ConvertTo-CimcXmlValue $Cookie
    $body = "<configResolveDn cookie=`"$safeCookie`" dn=`"sys/huu/firmwareUpdater/updateStatus`" inHierarchical=`"true`"/>"
    $text = Send-CimcXmlRequest -CimcIp $CimcIp -Body $body -TimeoutSec 90
    if ($text -match 'errorCode="([^"]+)"' -and $Matches[1]) {
        $why = ([regex]::Match($text, 'errorDescr="([^"]*)"')).Groups[1].Value
        throw "CIMC status query failed: $why"
    }
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($text)
    $status = $doc.GetElementsByTagName('huuFirmwareUpdateStatus') | Select-Object -First 1
    $components = @()
    foreach ($node in $doc.GetElementsByTagName('huuUpdateComponentStatus')) {
        $components += [pscustomobject]@{
            Name    = $node.GetAttribute('component')
            Update  = $node.GetAttribute('updateStatus')
            Verify  = $node.GetAttribute('verifyStatus')
            Running = $node.GetAttribute('runningVersion')
            New     = $node.GetAttribute('newVersion')
            Error   = $node.GetAttribute('errorDescription')
        }
    }
    return [pscustomobject]@{
        StartTime  = if ($status) { $status.GetAttribute('updateStartTime') } else { '' }
        EndTime    = if ($status) { $status.GetAttribute('updateEndTime') } else { '' }
        Overall    = if ($status) { $status.GetAttribute('overallStatus') } else { '' }
        Image      = if ($status) { $status.GetAttribute('huuImageVersion') } else { '' }
        Components = $components
    }
}

function Get-CimcHuuShare {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$IsoFile
    )
    $uri = [Uri]$BaseUrl
    $port = if ($uri.IsDefaultPort) { '' } else { ":$($uri.Port)" }
    $remoteIp = '{0}://{1}{2}' -f $uri.Scheme, $uri.Host, $port
    $path = $uri.AbsolutePath
    if (-not $path.EndsWith('/')) { $path += '/' }
    $remoteShare = ($path + $IsoFile) -replace '(?<!:)/{2,}', '/'
    # 6.0 accepts the URL in remoteIp. 4.3 validates remoteIp as a bare address
    # and takes the full http://host:port/file URL in remoteShare.
    return [pscustomobject]@{
        Ip       = $remoteIp
        Share    = $remoteShare
        Host     = $uri.Host
        ShareUrl = ($remoteIp.TrimEnd('/') + $remoteShare)
    }
}

function New-CimcHuuTriggerBody {
    param(
        [Parameter(Mandatory)][string]$Cookie,
        [Parameter(Mandatory)][string]$RemoteIp,
        [Parameter(Mandatory)][string]$RemoteShare,
        [string]$ShareUser,
        [string]$SharePass,
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][int]$TimeoutMin,
        [switch]$Legacy
    )
    $safeCookie = ConvertTo-CimcXmlValue $Cookie
    $xmlUser = ConvertTo-CimcXmlValue $ShareUser
    $xmlPass = ConvertTo-CimcXmlValue $SharePass
    # 6.0 accepts updateType, doForceDown, gracefulTimeout, and bootMedium.
    # 4.3 maps the ISO without those fields. Sending them with bootMedium
    # "vmedia" produced ISO Mapping Error before CIMC opened the URL.
    $newer = ''
    if (-not $Legacy) { $newer = ' updateType="immediate" doForceDown="yes" gracefulTimeout="3" bootMedium="vmedia"' }
    return @"
<configConfMo cookie="$safeCookie" dn="sys/huu/firmwareUpdater" inHierarchical="false">
  <inConfig>
    <huuFirmwareUpdater dn="sys/huu/firmwareUpdater" adminState="trigger" mapType="www" remoteIp="$(ConvertTo-CimcXmlValue $RemoteIp)" remoteShare="$(ConvertTo-CimcXmlValue $RemoteShare)" username="$xmlUser" password="$xmlPass" updateComponent="$(ConvertTo-CimcXmlValue $Component)" stopOnError="no" timeOut="$TimeoutMin" verifyUpdate="no"$newer status="modified"/>
  </inConfig>
</configConfMo>
"@
}

function Invoke-CimcHuuUpgrade {
    # Ask CIMC to boot the HUU ISO and run its non-interactive update.
    # "all" updates and activates every component except drives. "all,hdd"
    # includes drives. Leave drives out when a hypervisor install owns the disks.
    param(
        [Parameter(Mandatory)][string]$CimcIp,
        [Parameter(Mandatory)][string]$RemoteIp,
        [Parameter(Mandatory)][string]$RemoteShare,
        [string]$ShareUser,
        [string]$SharePass,
        [string]$MapRetryIp,
        [string]$MapRetryShare,
        [Parameter(Mandatory)][object]$Fw
    )
    $component = if ($Fw.updateComponent) { [string]$Fw.updateComponent } else { 'all' }
    $timeoutMin = if ($Fw.updateTimeoutMin) { [int]$Fw.updateTimeoutMin } else { 240 }
    if ($timeoutMin -lt 30) { $timeoutMin = 30 }
    if ($timeoutMin -gt 240) { $timeoutMin = 240 }

    Write-Log "Signing in to CIMC at https://$CimcIp/ to start the HUU update."
    $script:HuuJobStarted = $false
    $cookie = Wait-CimcXmlReady -CimcIp $CimcIp
    $prior = Get-CimcHuuStatus -CimcIp $CimcIp -Cookie $cookie
    $oldEnd = [string]$prior.EndTime
    $oldStart = [string]$prior.StartTime
    $oldOverall = [string]$prior.Overall

    $body = New-CimcHuuTriggerBody -Cookie $cookie -RemoteIp $RemoteIp -RemoteShare $RemoteShare `
        -ShareUser $ShareUser -SharePass $SharePass -Component $component -TimeoutMin $timeoutMin
    Write-Log "Starting HUU update and activate for '$component' from $RemoteIp$RemoteShare. CIMC allows up to $timeoutMin minutes. Leave this window open."
    Write-Host ''
    Write-Host "HUU is updating and activating every component except the drives. This often takes one to three hours." -ForegroundColor Yellow
    Write-Host "The ISO stays available from this laptop until CIMC reports the job finished." -ForegroundColor Yellow
    $trigger = Send-CimcXmlRequest -CimcIp $CimcIp -Body $body -TimeoutSec 180
    if ($trigger -match 'errorCode="([^"]+)"' -and $Matches[1]) {
        $why = ([regex]::Match($trigger, 'errorDescr="([^"]*)"')).Groups[1].Value
        if (-not $why) { $why = 'CIMC rejected the HUU update request.' }
        throw $why
    }
    $script:HuuJobStarted = $true

    $deadline = (Get-Date).AddMinutes($timeoutMin + 30)
    $seenActive = $false
    $mapAttempt = 0
    $retryPolls = 0
    $lastSummary = ''
    $lastBeat = [datetime]::MinValue
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        $status = $null
        try {
            if (-not $cookie) { $cookie = Connect-CimcXml -CimcIp $CimcIp }
            $status = Get-CimcHuuStatus -CimcIp $CimcIp -Cookie $cookie
        }
        catch {
            Write-Log "CIMC HTTPS is not answering ($($_.Exception.Message)). Firmware activation reboots CIMC. Still waiting."
            $cookie = $null
            continue
        }
        $start = [string]$status.StartTime
        $end = [string]$status.EndTime
        $overall = [string]$status.Overall
        if ($start -and $start -ne $oldStart -and $start -notmatch '^(NA|N/A|none)?$') { $seenActive = $true }
        if ($overall -and $overall -ne $oldOverall -and $overall -match '(?i)progress|running|updating|activat|boot|trigger') { $seenActive = $true }
        if ($overall -match '(?i)mapping error') { $seenActive = $true }
        $done = 0; $running = 0; $skipped = 0
        foreach ($item in @($status.Components)) {
            if ($item.Update -match '(?i)complete|success') { $done++ }
            elseif ($item.Update -match '(?i)progress|running') { $running++ }
            elseif ($item.Update -match '(?i)skip') { $skipped++ }
        }
        $phrase = $overall
        if ($phrase -match '\s{2,}') { $phrase = ($phrase -split '\s{2,}', 2)[0].Trim() }
        $summary = "HUU: $phrase"
        if (@($status.Components).Count -gt 0) {
            $summary = "$summary. Completed $done, in progress $running, skipped $skipped."
        }
        if ($summary -and $summary -ne $lastSummary) {
            $lastSummary = $summary
            Write-Log $summary
        }
        elseif (((Get-Date) - $lastBeat).TotalSeconds -ge 120) {
            $lastBeat = Get-Date
            Write-Log 'HUU is still running. The ISO server stays up.'
        }
        if ($mapAttempt -gt 0 -and $overall -match '(?i)ISO Mapping Error') {
            $retryPolls++
            if ($retryPolls -ge 6) {
                throw "HUU finished with failures: $overall. CIMC never opened the ISO URL. Confirm the CIMC management IP can reach the laptop address and port in that URL."
            }
        }
        $endIsNew = $end -and $end -notmatch '^(NA|N/A|none|null)?$' -and $end -ne $oldEnd
        if ($seenActive -and $endIsNew) {
            Write-Log "HUU finished. Image '$($status.Image)'. Overall: $overall"
            $failed = @()
            foreach ($item in @($status.Components)) {
                $detail = "{0}: update={1}; verify={2}; running={3}; new={4}" -f $item.Name, $item.Update, $item.Verify, $item.Running, $item.New
                if ($item.Error -and $item.Error -notmatch '^(?i)(NA|N/A|-|none)$') { $detail = "$detail; error=$($item.Error)" }
                Write-Log $detail
                if (($item.Update + ' ' + $item.Error) -match '(?i)fail|error') { $failed += $item.Name }
            }
            if ($failed.Count -gt 0 -or $overall -match '(?i)\b(fail|error)\b') {
                $which = if ($failed.Count -gt 0) { $failed -join ', ' } else { $overall }
                if ($overall -match '(?i)ISO Mapping Error' -and $mapAttempt -lt 2 -and $MapRetryIp -and $MapRetryShare) {
                    $mapAttempt++
                    $retryPolls = 0
                    $oldEnd = $end
                    $oldStart = $start
                    $oldOverall = $overall
                    $seenActive = $false
                    $lastSummary = ''
                    if (-not $cookie) { $cookie = Connect-CimcXml -CimcIp $CimcIp }
                    if ($mapAttempt -eq 1) {
                        Write-Log "CIMC reported ISO Mapping Error for $RemoteIp$RemoteShare and did not open that URL. Retrying without the 6.0-only HUU fields."
                        $body = New-CimcHuuTriggerBody -Cookie $cookie -RemoteIp $RemoteIp -RemoteShare $RemoteShare `
                            -ShareUser $ShareUser -SharePass $SharePass -Component $component -TimeoutMin $timeoutMin -Legacy
                    }
                    else {
                        Write-Log "CIMC still could not map the ISO. Retrying with IP $MapRetryIp and share $MapRetryShare."
                        $body = New-CimcHuuTriggerBody -Cookie $cookie -RemoteIp $MapRetryIp -RemoteShare $MapRetryShare `
                            -ShareUser $ShareUser -SharePass $SharePass -Component $component -TimeoutMin $timeoutMin -Legacy
                    }
                    $trigger = Send-CimcXmlRequest -CimcIp $CimcIp -Body $body -TimeoutSec 180
                    if ($trigger -match 'errorCode="([^"]+)"' -and $Matches[1]) {
                        $why = ([regex]::Match($trigger, 'errorDescr="([^"]*)"')).Groups[1].Value
                        if (-not $why) { $why = 'CIMC rejected the HUU update request.' }
                        throw $why
                    }
                    continue
                }
                if ($overall -match '(?i)ISO Mapping Error') {
                    throw "HUU finished with failures: $which. CIMC never opened the ISO URL. Confirm the CIMC management IP can reach the laptop address and port in that URL."
                }
                throw "HUU finished with failures: $which"
            }
            return
        }
    }
    throw "HUU did not finish within $($timeoutMin + 30) minutes."
}

function Repair-CimcBootAfterHuu {
    # The upgrade used a one-time boot of the ISO. Put the local drive first
    # and drop the mapping so the next reboot is the installed system.
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Fw
    )
    $cmdTO   = [int]$Config.behavior.commandTimeoutSec
    $delayMs = [int]$Config.behavior.interCommandDelayMs
    $volume  = if ($Fw.vmediaVolume) { [string]$Fw.vmediaVolume } else { 'firmware' }
    $lunName = if ($Fw.localBootName) { [string]$Fw.localBootName } else { 'LocalLUN' }
    $shellName = if ($Fw.uefiShellName) { [string]$Fw.uefiShellName } else { 'UefiShell' }
    try {
        if (-not (Sync-CimcPrompt -Port $Port -Attempts 3 -TimeoutSec 5)) {
            Invoke-CimcLogin -Port $Port -Behavior $Config.behavior
        }
        Remove-CimcVmediaMap -Port $Port -Config $Config -Volume $volume
        Send-Command -Port $Port -Command 'scope bios' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        $listed = Send-Command -Port $Port -Command 'show boot-device' -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs
        $known = @(Get-CimcBootDeviceNames -Text $listed)
        if ($known.Count -eq 0) {
            Write-Log 'CIMC has no precision boot devices. The BIOS default order is used, and the ISO mapping was removed.'
            return
        }
        if ($known -notcontains $lunName) {
            Write-Log -Level WARN "Boot device '$lunName' is not in the CIMC list. The ISO mapping was removed. Put the boot drive first in the CIMC boot order if the server comes back on the HUU."
            return
        }
        $ordered = @($lunName)
        foreach ($name in $known) {
            if ($name -ne $lunName -and $name -ne $shellName -and $ordered -notcontains $name) { $ordered += $name }
        }
        if ($known -contains $shellName) { $ordered += $shellName }
        $pairs = @()
        for ($i = 0; $i -lt $ordered.Count; $i++) { $pairs += ('{0}:{1}' -f $ordered[$i], ($i + 1)) }
        $rearrange = 'rearrange-boot-device ' + ($pairs -join ',')
        Write-Log "Restoring the boot drive to the top: $rearrange"
        Send-Command -Port $Port -Command $rearrange -ExpectPatterns @('#\s*$', '(?i)invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    }
    catch {
        Write-Log -Level WARN "The upgrade finished, but the boot drive was not moved back to the top: $($_.Exception.Message)"
    }
}

function Remove-CimcVmediaMap {
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Volume
    )
    $cmdTO   = [int]$Config.behavior.commandTimeoutSec
    $delayMs = [int]$Config.behavior.interCommandDelayMs
    Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'scope vmedia' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    $unmap = Send-Command -Port $Port -Command "unmap $Volume" `
        -ExpectPatterns @($script:RxCli, "(?i)enter 'yes' or 'no'", '(?i)does not exist', '(?i)not found', '(?i)invalid') `
        -TimeoutSec $cmdTO -InterDelayMs $delayMs
    if ($unmap -match "(?i)enter 'yes' or 'no'" -and $unmap -notmatch $script:RxCli) {
        Send-Command -Port $Port -Command 'no' -ExpectPatterns @($script:RxCli, '(?i)invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    }
    Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
}

function Invoke-CimcHostReboot {
    # Power-cycle the host, or power it on if it is already off. Used to boot
    # the HUU ISO. 'power cycle' is refused on a powered-off host.
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Config,
        [string]$Reason = 'apply the new settings',
        [switch]$OnlyIfOff
    )
    $cmdTO   = [int]$Config.behavior.commandTimeoutSec
    $delayMs = [int]$Config.behavior.interCommandDelayMs
    Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'scope chassis' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    $detail = Send-Command -Port $Port -Command 'show detail' -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs
    $state = ''
    $m = [regex]::Match($detail, '(?im)^\s*Power(?:\s+State)?\s*:\s*(on|off)\b')
    if ($m.Success) { $state = $m.Groups[1].Value.ToLower() }

    if ($state -eq 'off') {
        Write-Log "Host is powered off. Powering it on to $Reason."
        $resp = Send-CimcConfirm -Port $Port -Command 'power on' -TimeoutSec $cmdTO -InterDelayMs $delayMs
    }
    elseif ($OnlyIfOff) {
        Write-Log 'Host is already powered on.'
        Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        return
    }
    else {
        Write-Log "Power-cycling the host to $Reason."
        $resp = Send-CimcConfirm -Port $Port -Command 'power cycle' -TimeoutSec $cmdTO -InterDelayMs $delayMs
        if ($resp -match '(?i)powered off|is off|not powered') {
            Write-Log 'CIMC reports the host is off. Powering it on.'
            $resp = Send-CimcConfirm -Port $Port -Command 'power on' -TimeoutSec $cmdTO -InterDelayMs $delayMs
        }
    }
    if ($resp -match '(?i)invalid') {
        Write-Log -Level WARN "CIMC rejected the power command. Reboot the server from the CIMC UI to $Reason."
    }
    Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
}

function Invoke-CimcPowerCycle {
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Config
    )
    Invoke-CimcHostReboot -Port $Port -Config $Config -Reason 'boot the mapped ISO'
}

function Wait-CimcXmlReady {
    # A network or hostname commit restarts the CIMC web server and can
    # regenerate its certificate. Wait for the XML API before sending the HUU job.
    param(
        [Parameter(Mandatory)][string]$CimcIp,
        [int]$TimeoutSec = 600
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastWhy = ''
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            return (Connect-CimcXml -CimcIp $CimcIp)
        }
        catch {
            $lastWhy = $_.Exception.Message
            if ($lastWhy -match '(?i)login failed') { throw }
            Write-Log ("CIMC HTTPS at {0} is not ready yet ({1}s). Retrying." -f $CimcIp, [int]$sw.Elapsed.TotalSeconds)
            Start-Sleep -Seconds 15
        }
    }
    throw "CIMC HTTPS at $CimcIp did not answer within ${TimeoutSec}s: $lastWhy"
}

function Invoke-FirmwareUpgrade {
    param(
        # Named SerialPort, not Port. $port is the same variable as $Port in
        # PowerShell, and this function also needs an HTTP listen port.
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$SerialPort,
        [Parameter(Mandatory)][object]$Config,
        [string]$TargetIp
    )
    $fw = $Config.firmware

    # Resolve settings (CLI overrides win over the config file).
    $isoFolder = if ($script:IsoFolderOverride) { $script:IsoFolderOverride } elseif ($fw.isoFolder) { [string]$fw.isoFolder } else { $null }
    $isoFile   = if ($script:IsoFileOverride)   { $script:IsoFileOverride }   elseif ($fw.isoFile)   { [string]$fw.isoFile }   else { $null }
    $transport = if ($fw.transport) { [string]$fw.transport } else { 'http-local' }
    $volume     = if ($fw.vmediaVolume) { [string]$fw.vmediaVolume } else { 'firmware' }
    $listenPort = if ($fw.servePort) { [int]$fw.servePort } else { 8000 }
    $powerCyc   = if ($fw.PSObject.Properties.Name -contains 'powerCycle') { [bool]$fw.powerCycle } else { $true }

    if (-not $isoFile) { throw 'Firmware step is enabled but no ISO file name was provided (firmware.isoFile or -IsoFile).' }

    $server = $null
    try {
        if ($transport -ieq 'http-local') {
            if (-not $isoFolder) { throw 'firmware.transport is "http-local" but no folder was provided (firmware.isoFolder or -IsoFolder).' }
            $isoPath = Join-Path $isoFolder $isoFile
            if (-not (Test-Path -LiteralPath $isoPath)) {
                throw "ISO not found: '$isoPath'. Put the firmware ISO in the folder and check the file name."
            }
            $serveHost = Get-ServeHostAddress -Override ([string]$fw.serveHost) -TargetIp $TargetIp -SubnetMask ([string]$Config.site.subnetMask)
            if (-not $serveHost) { throw 'Could not determine a local IP to serve the ISO from. Set firmware.serveHost explicitly.' }
            $mask = [string]$Config.site.subnetMask
            if ($TargetIp -and $mask -and -not (Test-IpInSubnet -A $serveHost -B $TargetIp -Mask $mask)) {
                throw "Laptop address $serveHost is not on the CIMC subnet ($TargetIp / $mask). The CIMC cannot mount an ISO from that address. Clear firmware.serveHost so the script can choose the Ethernet NIC on the CIMC subnet, or set serveHost to that Ethernet IP. Reaching the CIMC web page from the laptop does not mean the CIMC can connect back to this address."
            }
            $ifName = Get-IPv4InterfaceName -Address $serveHost
            if ($ifName) {
                Write-Log "ISO will be served from $serveHost on interface '$ifName'."
                if ($ifName -match '(?i)wi-?fi|wireless|wlan') {
                    Write-Log -Level WARN "That address is on '$ifName'. The CIMC can only mount the ISO from the NIC cabled to the CIMC management port. Put a static IP on that Ethernet adapter and leave firmware.serveHost empty, or set serveHost to the Ethernet IP."
                }
            }
            $python = Resolve-PythonCommand
            Add-IsoHttpFirewallRule -ListenPort $listenPort -Program $python.Source
            # 0.0.0.0 so both 127.0.0.1 and the Ethernet IP hit this process.
            # The URL handed to CIMC is still the Ethernet address.
            $server  = Start-IsoHttpServer -Folder $isoFolder -ListenPort $listenPort -BindAddress '0.0.0.0'
            # Keep the trailing slash. map-www joins the share and the file name,
            # and without the slash this CIMC requests http://host:8000filename.iso.
            $baseUrl = "http://${serveHost}:${listenPort}/"
            $loopUrl = "http://127.0.0.1:${listenPort}/"
            Write-Log "Serving ISO to CIMC at ${baseUrl}${isoFile} (the CIMC's IP must be able to reach ${serveHost}:${listenPort})."
            Write-Host ''
            Write-Host "ISO server is listening on port $listenPort." -ForegroundColor Yellow
            Write-Host "  This laptop:  $loopUrl" -ForegroundColor Yellow
            Write-Host "  CIMC uses:    ${baseUrl}${isoFile}" -ForegroundColor Yellow
            $loopOk = Test-IsoHttpReachable -Url $loopUrl
            $lanOk  = Test-IsoHttpReachable -Url $baseUrl
            if (-not $loopOk) {
                throw "Python did not answer $loopUrl. The ISO server is not running on port $listenPort. Close anything else using that port and run the script again."
            }
            if (-not $lanOk) {
                $admin = if (Test-IsWindowsAdmin) { 'The firewall allow rule still failed.' } else { 'Re-run this PowerShell window as Administrator so the script can allow inbound TCP ' + $listenPort + '.' }
                Write-Host ''
                Write-Host "http://127.0.0.1:${listenPort}/ answers. http://${serveHost}:${listenPort}/ does not." -ForegroundColor Red
                Write-Host "Windows is blocking inbound connections to the Ethernet address. The CIMC uses that address, so the mount cannot work until a browser or curl on this laptop can open it." -ForegroundColor Red
                Write-Host $admin -ForegroundColor Red
                Write-Host "If a Windows Security prompt for Python is hiding behind this window, choose Allow. A browser on Wi-Fi may also send this address to a proxy. Test with the server still running:" -ForegroundColor Yellow
                Write-Host "  curl.exe --noproxy `"*`" $loopUrl" -ForegroundColor Yellow
                Write-Host "  curl.exe --noproxy `"*`" $baseUrl" -ForegroundColor Yellow
                Write-Host 'Press Enter to stop the server...' -ForegroundColor Yellow
                [void](Read-Host)
                throw "This laptop cannot open http://${serveHost}:${listenPort}/ (port $listenPort). http://127.0.0.1:${listenPort}/ works, so Python is running and Windows is blocking the Ethernet address. $admin"
            }
            if (-not (Test-IsoHttpReachable -Url "${baseUrl}${isoFile}" -Range)) {
                throw "The server is up at $baseUrl but the ISO URL failed its byte-range test. CIMC requires HTTP 206 Partial Content with Content-Range and Accept-Ranges headers. Check firmware.isoFile and that the file is directly in the serve folder."
            }
            if (-not (Test-IsoHttpReachable -Url ("http://{0}:{1}//{2}" -f $serveHost, $listenPort, $isoFile) -Range)) {
                throw "The server rejected the double-slash ISO URL CIMC sometimes requests."
            }
            Start-Sleep -Milliseconds 500
            Write-Log "HTTP lines above are this laptop checking the ISO. A later HTTP line from the CIMC address means the mount reached the laptop."
        }
        elseif ($transport -ieq 'url') {
            $baseUrl = ([string]$fw.shareUrl).Trim().TrimEnd('/')
            if (-not $baseUrl) { throw 'firmware.transport is "url" but firmware.shareUrl is not set.' }
            $baseUrl = "${baseUrl}/"
        }
        else {
            throw "Unknown firmware.transport '$transport' (expected 'http-local' or 'url')."
        }

        if (-not $TargetIp) { throw 'The server entry has no ipAddress, so the HUU update cannot be started.' }
        $share = Get-CimcHuuShare -BaseUrl $baseUrl -IsoFile $isoFile
        $upgraded = $false
        $script:HuuJobStarted = $false
        $huuError = $null
        # HUU mounts the ISO itself. A volume left from an earlier run can hold
        # the CIMC-mapped DVD slot and stop that mount. Recover the prompt
        # first: a Device Connector commit on 4.3 can leave the CLI silent.
        if (-not (Restore-CimcCli -Port $SerialPort)) {
            Write-Log -Level WARN 'The serial console did not return a prompt before the ISO unmap.'
        }
        try { Remove-CimcVmediaMap -Port $SerialPort -Config $Config -Volume $volume }
        catch { Write-Log -Level WARN "Could not clear an earlier ISO mapping: $($_.Exception.Message)" }
        try {
            Invoke-CimcHuuUpgrade -CimcIp $TargetIp -RemoteIp $share.Ip -RemoteShare $share.Share `
                -MapRetryIp $share.Host -MapRetryShare $share.ShareUrl `
                -ShareUser ([string]$fw.shareUser) -SharePass ([string]$fw.sharePassword) -Fw $fw
            $upgraded = $true
        }
        catch {
            $huuError = $_.Exception.Message
            if ($script:CimcPassword -and $huuError.Contains($script:CimcPassword)) { $huuError = $huuError.Replace($script:CimcPassword, '<redacted>') }
            Write-Log -Level WARN "Automatic HUU update did not finish: $huuError"
        }

        if ($upgraded) {
            Repair-CimcBootAfterHuu -Port $SerialPort -Config $Config -Fw $fw
            # The HUU boot was this run's reboot. Only power the host back on
            # if HUU left it off.
            try { Invoke-CimcHostReboot -Port $SerialPort -Config $Config -Reason 'boot the installed system' -OnlyIfOff }
            catch { Write-Log -Level WARN "Could not check the host power state after the upgrade: $($_.Exception.Message)" }
            Write-Host ''
            Write-Host "Firmware update and activate finished. The server is set to boot its drive." -ForegroundColor Yellow
        }
        elseif ($script:HuuJobStarted -and $huuError -notmatch '(?i)ISO Mapping Error') {
            throw $huuError
        }
        else {
            # 4.3 accepts the HUU job and then fails the mount before it opens
            # the URL. map-www is the mount that carries the port. A browser on
            # this laptop can download the ISO even when CIMC never connects.
            if ($huuError -match '(?i)ISO Mapping Error') {
                Write-Log 'The HUU API could not map the ISO and CIMC never opened the URL. Mapping it with map-www. A browser on this laptop is not the same as CIMC connecting.'
                if (-not (Restore-CimcCli -Port $SerialPort)) {
                    throw "$huuError The serial console is not answering, so map-www cannot run either."
                }
            }
            # CIMC did not accept the non-interactive job. Fall back to mapping
            # the ISO and booting it so the HUU menu is reachable.
            Set-CimcVmediaMap -Port $SerialPort -Config $Config -Volume $volume -BaseUrl $baseUrl -IsoFile $isoFile `
                -User ([string]$fw.shareUser) -Pass ([string]$fw.sharePassword) | Out-Null
            $bootOrderSet = $false
            try {
                if (-not (Sync-CimcPrompt -Port $SerialPort -Attempts 3 -TimeoutSec 5)) {
                    throw "The serial console did not return a prompt after the ISO was mapped."
                }
                Set-CimcVmediaBootOrder -Port $SerialPort -Config $Config -Fw $fw
                if ($powerCyc) { Invoke-CimcPowerCycle -Port $SerialPort -Config $Config }
                $bootOrderSet = $true
            }
            catch {
                Write-Log -Level WARN "ISO is mapped, but the boot order was not changed: $($_.Exception.Message)"
            }
            if ($server) {
                Write-Host ''
                if ($bootOrderSet) {
                    Write-Host "Automatic HUU did not start. The ISO is mapped and the server is booting to it." -ForegroundColor Yellow
                    Write-Host "In the HUU screen, choose Update and Activate for all components except the drives." -ForegroundColor Yellow
                } else {
                    Write-Host "Automatic HUU did not start, and the serial console stopped answering." -ForegroundColor Yellow
                    Write-Host "In CIMC, boot the mapped vDVD, then choose Update and Activate for all components." -ForegroundColor Yellow
                }
                Write-Host "The local HTTP server must stay running while the CIMC reads the ISO." -ForegroundColor Yellow
                Write-Host "Press Enter here ONLY when the upgrade is complete to stop serving the ISO..." -ForegroundColor Yellow
                [void](Read-Host)
            }
        }
    }
    finally {
        if ($server) { Stop-IsoHttpServer -Proc $server }
    }
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

    # Stored so Reset-CimcPort can perform a true drop/reconnect (dispose + new
    # port object) when the CIMC console resets after a password change/reboot.
    $script:PortName     = $ComPort
    $script:SerialConfig = $Config.serial
    $script:Port         = $null
    try {
        $script:Port = Open-CimcSerial -PortName $ComPort -Serial $Config.serial
        Invoke-CimcLogin           -Port $script:Port -Behavior $Config.behavior
        Set-CimcNetwork            -Port $script:Port -Config $Config -Ip $ip -Hostname $hn `
                                   -PrimaryDns $dns1 -SecondaryDns $dns2 -DnsDomain $domain
        Start-Sleep -Seconds 3
        Set-CimcNtp                -Port $script:Port -Config $Config -NtpServers $ntp
        # Everything above is already committed, so a hiccup here must not fail
        # the whole run. Report it and continue to the firmware step / logout.
        try {
            Enable-IntersightDeviceConnector -Port $script:Port -Config $Config
        }
        catch {
            Write-Log -Level WARN "Intersight Device Connector step did not complete: $($_.Exception.Message). All other configuration was committed; enable it from Admin > Device Connector if needed."
        }
        if ($script:FirmwareEnabled) {
            Write-Log 'Firmware step enabled: running the HUU update.'
            Invoke-FirmwareUpgrade -SerialPort $script:Port -Config $Config -TargetIp $ip
        }
        Invoke-CimcLogout          -Port $script:Port
        Write-Log "===== Finished configuration for $hn ($ip) ====="
    }
    catch {
        Write-Log -Level ERROR "Failed configuring $hn ($ip): $($_.Exception.Message)"
        throw
    }
    finally {
        if ($script:Port -and $script:Port.IsOpen) { $script:Port.Close(); $script:Port.Dispose() }
    }
}

# -------------------- Entrypoint --------------------
try {
    Write-Log "Log file:    $script:SessionLog"
    Write-Log "Config file: $ConfigPath"

    $Config = Read-CimcConfig -Path $ConfigPath
    Resolve-Credentials -Config $Config

    # Firmware step: on if -Firmware is passed, or firmware.enabled is true.
    $script:IsoFileOverride   = if ($PSBoundParameters.ContainsKey('IsoFile'))   { $IsoFile }   else { $null }
    $script:IsoFolderOverride = if ($PSBoundParameters.ContainsKey('IsoFolder')) { $IsoFolder } else { $null }
    $script:FirmwareEnabled   = [bool]$Firmware
    if (-not $script:FirmwareEnabled -and $Config.PSObject.Properties.Name -contains 'firmware' -and $Config.firmware) {
        if ($Config.firmware.PSObject.Properties.Name -contains 'enabled') {
            $script:FirmwareEnabled = [bool]$Config.firmware.enabled
        }
    }
    if ($script:FirmwareEnabled -and -not ($Config.PSObject.Properties.Name -contains 'firmware' -and $Config.firmware)) {
        throw 'Firmware step requested but the config has no "firmware" block. Add one to cimc-config.jsonc (see the sample).'
    }

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
