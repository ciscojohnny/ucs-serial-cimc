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

    [string]$LogDirectory = (Join-Path $PSScriptRoot 'logs'),

    # Firmware upgrade via CIMC-mapped vMedia. When present, forces the firmware
    # step on for this run (overrides "firmware".enabled=false in the config).
    # The ISO is served from a local folder over HTTP and the CIMC is set to
    # boot from the mapped vDVD first, then the local LUN.
    [switch]$Firmware,

    # Optional per-run overrides for the firmware step (otherwise taken from the
    # "firmware" block in the config file).
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
        Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        Send-Command -Port $Port -Command 'scope cimc' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        $tzResp = Send-Command -Port $Port -Command ("set-timezone {0}" -f $Config.site.timezone) `
            -ExpectPatterns @('#\s*$','Invalid','Unrecognized') -TimeoutSec 10 -InterDelayMs $delayMs
        if ($tzResp -match 'Invalid|Unrecognized') {
            Send-Command -Port $Port -Command 'scope clock' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
            Send-Command -Port $Port -Command ("set timezone {0}" -f $Config.site.timezone) `
                -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
            Send-Command -Port $Port -Command 'commit' -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
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

    # Observed on C220 M7N: this scope answers these 'set' commands faster than
    # the reader consumes them, so reads drift a prompt behind and the last one
    # starves with an empty buffer. Resync first, then send each setting
    # best-effort so a silent console cannot fail an otherwise-complete run.
    Sync-CimcPrompt -Port $Port | Out-Null

    Send-CimcBestEffort -Port $Port -Command 'set enabled yes'              -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
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

    # The settings above are only staged until this commit lands, so retry it
    # once after a resync before giving up.
    try {
        Send-CimcConfirm -Port $Port -Command 'commit' -TimeoutSec 30 -InterDelayMs $delayMs | Out-Null
    }
    catch {
        Write-Log -Level WARN "Device Connector commit did not confirm: $($_.Exception.Message)"
        Sync-CimcPrompt -Port $Port | Out-Null
        Send-CimcBestEffort -Port $Port -Command 'commit' -TimeoutSec 30 -InterDelayMs $delayMs | Out-Null
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

# -------------------- Firmware upgrade via CIMC-mapped vMedia --------------------
# The CIMC reads virtual media over its OWN management IP network (NOT over the
# serial cable). So to boot an ISO that lives "on the laptop", the laptop must
# run a web server that the CIMC's configured IP can reach, and we map the ISO
# with `scope vmedia` / `map-www`. We then set the precision boot order so the
# CIMC boots the mapped vDVD first and the local LUN second, and power-cycle.

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

function Start-IsoHttpServer {
    # Serve $Folder over HTTP on $Port using Python's built-in server. Returns
    # the running Process object (kept alive until the upgrade finishes).
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][int]$Port
    )
    if (-not (Test-Path -LiteralPath $Folder)) {
        throw "Firmware folder not found: '$Folder'."
    }
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
    if (-not $python) {
        throw "python3 is required to serve the ISO locally (transport 'http-local'). Install Python 3, or set firmware.transport to 'url' and provide firmware.shareUrl."
    }
    $full = (Resolve-Path -LiteralPath $Folder).Path
    Write-Log "Starting local HTTP server: folder='$full' port=$Port (python: $($python.Source))"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $python.Source
    $psi.Arguments              = "-m http.server $Port --bind 0.0.0.0"
    $psi.WorkingDirectory       = $full
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Seconds 1
    if ($proc.HasExited) {
        throw "Local HTTP server exited immediately (is port $Port already in use?)."
    }
    return $proc
}

function Stop-IsoHttpServer {
    param([System.Diagnostics.Process]$Proc)
    if ($Proc -and -not $Proc.HasExited) {
        try { $Proc.Kill() } catch {}
        try { $Proc.WaitForExit(3000) | Out-Null } catch {}
        Write-Log 'Local HTTP server stopped.'
    }
}

function Set-CimcVmediaMap {
    # Map the ISO into a CIMC vMedia volume and verify Map-Status is OK.
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
    Send-CimcConfirm -Port $Port -Command "unmap $Volume" -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null

    Write-Log "Mapping vMedia volume '$Volume' -> ${BaseUrl}${IsoFile}"
    # map-www {volume-name} {remote-share} {remote-file}
    $resp = Send-Command -Port $Port -Command ("map-www {0} {1} {2}" -f $Volume, $BaseUrl, $IsoFile) `
        -ExpectPatterns @('#\s*$', '(?i)user\s*name:\s*$', '(?i)password:\s*$', 'Invalid', 'Error') `
        -TimeoutSec $cmdTO -InterDelayMs $delayMs

    # map-www may prompt for credentials; answer with provided creds or blanks.
    $guard = 4
    while ($guard-- -gt 0 -and ($resp -match '(?i)user\s*name:\s*$' -or $resp -match '(?i)password:\s*$')) {
        if ($resp -match '(?i)user\s*name:\s*$') {
            $resp = Send-Command -Port $Port -Command ([string]$User) `
                -ExpectPatterns @('#\s*$', '(?i)password:\s*$', 'Invalid', 'Error') -TimeoutSec $cmdTO -InterDelayMs $delayMs
        }
        elseif ($resp -match '(?i)password:\s*$') {
            $resp = Send-Command -Port $Port -Command ([string]$Pass) `
                -ExpectPatterns @('#\s*$', 'Invalid', 'Error') -TimeoutSec $cmdTO -InterDelayMs $delayMs -Sensitive
        }
    }

    # Give the CIMC a moment to fetch headers, then verify.
    Start-Sleep -Seconds 3
    $status = Send-Command -Port $Port -Command 'show mappings detail' `
        -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs

    if ($status -match '(?i)Map-Status\s*:\s*OK' -or $status -match "(?i)$([regex]::Escape($Volume))\s+OK") {
        Write-Log "vMedia mapping '$Volume' reported Map-Status OK."
    } else {
        Write-Log -Level WARN "vMedia mapping '$Volume' did not report OK. Check reachability from the CIMC to $BaseUrl (firewall / laptop on the mgmt network?). show mappings output was logged."
    }
    return $status
}

function Set-CimcVmediaBootOrder {
    # Precision boot order: mapped vDVD first, local LUN second.
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Fw
    )
    $cmdTO   = [int]$Config.behavior.commandTimeoutSec
    $delayMs = [int]$Config.behavior.interCommandDelayMs

    $dvdName   = if ($Fw.dvdBootName)   { [string]$Fw.dvdBootName }   else { 'vDVD' }
    $dvdSub    = if ($Fw.vmediaSubtype) { [string]$Fw.vmediaSubtype } else { 'CIMCMAPPEDDVD' }
    $lunName   = if ($Fw.localBootName) { [string]$Fw.localBootName } else { 'LocalLUN' }
    $lunType   = if ($Fw.localBootType) { [string]$Fw.localBootType } else { 'LOCALHDD' }

    Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'scope bios' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null

    # Log the existing boot devices for reference/troubleshooting.
    $existing = Send-Command -Port $Port -Command 'show boot-device' -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs
    Write-Log "Existing precision boot devices:`n$existing"

    # ---- Mapped vDVD as boot device #1 ----
    Send-CimcConfirm -Port $Port -Command ("create-boot-device {0} VMEDIA" -f $dvdName) -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-CimcConfirm -Port $Port -Command 'commit' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command ("scope boot-device {0}" -f $dvdName) -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    $subResp = Send-Command -Port $Port -Command ("set subtype {0}" -f $dvdSub) -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs
    if ($subResp -match 'Invalid') {
        Write-Log -Level WARN "vMedia boot subtype '$dvdSub' was rejected; run 'set subtype' with no value under scope boot-device $dvdName to list valid tokens (varies by firmware). Continuing without an explicit subtype."
    }
    Send-Command -Port $Port -Command 'set order 1'      -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'set state Enabled' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-CimcConfirm -Port $Port -Command 'commit' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'exit' -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null

    # ---- Local LUN as boot device #2 ----
    $lunScope = Send-Command -Port $Port -Command ("scope boot-device {0}" -f $lunName) -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs
    if ($lunScope -match 'Invalid') {
        Send-CimcConfirm -Port $Port -Command ("create-boot-device {0} {1}" -f $lunName, $lunType) -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        Send-CimcConfirm -Port $Port -Command 'commit' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
        Send-Command -Port $Port -Command ("scope boot-device {0}" -f $lunName) -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    }
    Send-Command -Port $Port -Command 'set order 2'      -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'set state Enabled' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-CimcConfirm -Port $Port -Command 'commit' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'exit' -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null

    $final = Send-Command -Port $Port -Command 'show boot-device' -ExpectPatterns @('#\s*$') -TimeoutSec $cmdTO -InterDelayMs $delayMs
    Write-Log "Configured precision boot order:`n$final"
}

function Invoke-CimcPowerCycle {
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Config
    )
    $cmdTO   = [int]$Config.behavior.commandTimeoutSec
    $delayMs = [int]$Config.behavior.interCommandDelayMs
    Write-Log 'Power-cycling the server to boot the mapped ISO.'
    Send-Command -Port $Port -Command 'top' -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    Send-Command -Port $Port -Command 'scope chassis' -ExpectPatterns @('#\s*$','Invalid') -TimeoutSec $cmdTO -InterDelayMs $delayMs | Out-Null
    $resp = Send-CimcConfirm -Port $Port -Command 'power cycle' -TimeoutSec $cmdTO -InterDelayMs $delayMs
    if ($resp -match 'Invalid') {
        Write-Log -Level WARN "'power cycle' was rejected under scope chassis on this firmware; power-cycle the server manually to boot the ISO."
    }
}

function Invoke-FirmwareUpgrade {
    param(
        [Parameter(Mandatory)][System.IO.Ports.SerialPort]$Port,
        [Parameter(Mandatory)][object]$Config,
        [string]$TargetIp
    )
    $fw = $Config.firmware

    # Resolve settings (CLI overrides win over the config file).
    $isoFolder = if ($script:IsoFolderOverride) { $script:IsoFolderOverride } elseif ($fw.isoFolder) { [string]$fw.isoFolder } else { $null }
    $isoFile   = if ($script:IsoFileOverride)   { $script:IsoFileOverride }   elseif ($fw.isoFile)   { [string]$fw.isoFile }   else { $null }
    $transport = if ($fw.transport) { [string]$fw.transport } else { 'http-local' }
    $volume    = if ($fw.vmediaVolume) { [string]$fw.vmediaVolume } else { 'firmware' }
    $port      = if ($fw.servePort) { [int]$fw.servePort } else { 8000 }
    $powerCyc  = if ($fw.PSObject.Properties.Name -contains 'powerCycle') { [bool]$fw.powerCycle } else { $true }

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
            $server  = Start-IsoHttpServer -Folder $isoFolder -Port $port
            $baseUrl = "http://${serveHost}:${port}/"
            Write-Log "Serving ISO to CIMC at ${baseUrl}${isoFile} (the CIMC's IP must be able to reach ${serveHost}:${port})."
            Set-CimcVmediaMap -Port $Port -Config $Config -Volume $volume -BaseUrl $baseUrl -IsoFile $isoFile `
                -User ([string]$fw.shareUser) -Pass ([string]$fw.sharePassword) | Out-Null
        }
        elseif ($transport -ieq 'url') {
            $baseUrl = [string]$fw.shareUrl
            if (-not $baseUrl) { throw 'firmware.transport is "url" but firmware.shareUrl is not set.' }
            if ($baseUrl[-1] -ne '/') { $baseUrl += '/' }
            Set-CimcVmediaMap -Port $Port -Config $Config -Volume $volume -BaseUrl $baseUrl -IsoFile $isoFile `
                -User ([string]$fw.shareUser) -Pass ([string]$fw.sharePassword) | Out-Null
        }
        else {
            throw "Unknown firmware.transport '$transport' (expected 'http-local' or 'url')."
        }

        Set-CimcVmediaBootOrder -Port $Port -Config $Config -Fw $fw
        if ($powerCyc) { Invoke-CimcPowerCycle -Port $Port -Config $Config }

        if ($server) {
            Write-Host ''
            Write-Host "ISO is mapped and the server is booting to it. The local HTTP server must stay running" -ForegroundColor Yellow
            Write-Host "while the CIMC reads the media (this can take a long time for a firmware update)." -ForegroundColor Yellow
            Write-Host "Press Enter here ONLY when the upgrade is complete to stop serving the ISO..." -ForegroundColor Yellow
            [void](Read-Host)
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
            Write-Log 'Firmware step enabled: mapping ISO via vMedia and setting boot order.'
            Invoke-FirmwareUpgrade -Port $script:Port -Config $Config -TargetIp $ip
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
