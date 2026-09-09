# Deployment Guide: Configuring a Cisco UCS C-Series Server (CIMC) Over Serial

This guide walks you through configuring the CIMC (the management controller)
on a Cisco UCS C-Series server, step by step, on **Windows, macOS, or Linux**.

No prior PowerShell or networking-tool experience is required. If you can open a
text file and run a command in a terminal, you can complete this.

The script configures **one server at a time** over a single serial connection.
Keep an inventory of every server you'll eventually configure in
`cimc-config.jsonc` and run the script once per server.

---

## Table of Contents

1. [Overview](#1-overview)
2. [What you need](#2-what-you-need)
3. [Step 1 — Get the files onto your computer](#step-1--get-the-files-onto-your-computer)
4. [Step 2 — Install or verify PowerShell](#step-2--install-or-verify-powershell)
5. [Step 3 — Connect your computer to the UCS server](#step-3--connect-your-computer-to-the-ucs-server)
6. [Step 4 — Identify your serial port](#step-4--identify-your-serial-port)
7. [Step 5 — Edit `cimc-config.jsonc`](#step-5--edit-cimc-configjsonc)
8. [Step 6 — Run the script](#step-6--run-the-script)
9. [Step 7 — Claim the server in Intersight](#step-7--claim-the-server-in-intersight)
10. [Optional — Boot a firmware ISO (HUU) via vMedia](#optional--boot-a-firmware-iso-huu-via-vmedia)
11. [Troubleshooting](#troubleshooting)
12. [Glossary](#glossary)

---

## 1. Overview

Every UCS C-Series server has a small management computer inside it called
**CIMC** (Cisco Integrated Management Controller). It has its own IP address,
hostname, DNS, NTP, and password — completely separate from the operating
system that runs on the server.

Out of the factory, CIMC has no static IP address. Before the server can be
managed by **Intersight** (Cisco's cloud management portal), you have to log
into CIMC once and provide that information.

You'll do that by:

1. Connecting a serial cable from your computer to the back of the UCS server.
2. Running a PowerShell script on your computer.
3. The script logs into CIMC over the serial cable and configures everything
   for you — including the mandatory first-login password change on a
   factory-default CIMC.

When the script finishes, the CIMC is reachable on its new IP address. You then
open the CIMC web UI in a browser and copy the Device ID and Claim Code to
register the server with Intersight.

---

## 2. What you need

### Hardware

- A laptop or workstation running **Windows, macOS, or Linux**.
- A **USB-to-Serial adapter** (e.g., a generic FTDI or Prolific USB-serial cable).
- A **Cisco RJ-45 serial console cable**, or an RJ-45 to DB-9 (female) cable —
  the same style used for switch/router console ports.
- Access to the **back** of the UCS C-Series server.

On the back of a UCS C220/C240, look for a connector labeled **SERIAL** or
**CONSOLE**. It's an RJ-45 jack (looks like an Ethernet port), usually near the
management ports. Do **not** use the "Management" Ethernet port for this — use
the serial jack specifically.

### Software (all free)

- **PowerShell** — built in on Windows (5.1). On macOS and Linux, install
  **PowerShell 7+** (`pwsh`); see Step 2.
- Optional but nicer: **Visual Studio Code** for editing the config file.

### Information from your network team

Before you start, ask your network team for:

| Item                                            | Example             |
|-------------------------------------------------|---------------------|
| The static IP for the CIMC                      | `10.10.20.51`       |
| Subnet mask                                     | `255.255.255.0`     |
| Default gateway                                 | `10.10.20.1`        |
| Primary DNS server                              | `10.10.10.10`       |
| Secondary DNS server (if any)                   | `10.10.10.11`       |
| DNS domain name                                 | `example.lab`       |
| NTP server(s)                                   | `ntp1.example.lab`  |
| The hostname you want for the server            | `rack01-ucs01`      |
| VLAN ID for the management network (if tagged)  | usually none        |

You only need a **new CIMC admin password** if the CIMC is still at its factory
default (`admin` / `password`). In that case CIMC forces a password change at
first login, and the script will prompt you for the new password right then. On
a CIMC whose password has already been changed, the script will not ask about a
new password (only the current one, to log in).

---

## Step 1 — Get the files onto your computer

1. Copy the whole `UCS-CIMC-Config` folder to your computer.
   - Windows: e.g., `C:\Users\<your-name>\Desktop\UCS-CIMC-Config`
   - macOS/Linux: e.g., `~/Desktop/UCS-CIMC-Config`
2. Open that folder. You should see:
   - `Configure-CIMC.ps1`
   - `cimc-config.jsonc`
   - `README.md`
   - `DEPLOYMENT_GUIDE.md` (this file)

Do **not** rename or delete `Configure-CIMC.ps1` or `cimc-config.jsonc`.

---

## Step 2 — Install or verify PowerShell

### Windows

Windows already includes PowerShell 5.1 — nothing to install.

**Open it:** press the **Windows key**, type `powershell`, and click
**Windows PowerShell**.

**One-time: allow the script to run.** Windows blocks downloaded scripts by
default. Run this once, then press **Y** to confirm:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

### macOS

Install PowerShell 7 with [Homebrew](https://brew.sh):

```bash
brew install --cask powershell
```

Then start it by running `pwsh`. (The macOS execution-policy step is not
needed.)

### Linux

Install PowerShell 7 using your distribution's package (see Microsoft's
"Installing PowerShell on Linux" docs), then start it by running `pwsh`.

---

## Step 3 — Connect your computer to the UCS server

1. Plug the USB end of your USB-to-Serial adapter into your computer.
   - Windows usually installs a driver automatically. If not, install the
     adapter manufacturer's driver (FTDI, Prolific, etc.).
   - macOS may also need the vendor driver for some Prolific/FTDI clones.
2. Plug the RJ-45 end of the console cable into the **SERIAL** (or **CONSOLE**)
   jack on the back of the UCS server.
3. Plug the other end of the console cable into your USB-to-Serial adapter.
4. Make sure the UCS server has **AC power**. CIMC is available shortly after
   the server is plugged in; the host OS does not need to be booted.

That's it for the physical setup.

> **Tip:** to configure several servers from a cart, keep your computer and
> adapter on the cart and move only the RJ-45 end between server serial jacks,
> running the script once per server.

> **Important:** make sure no other terminal program (PuTTY, SecureCRT, Tera
> Term, `screen`, etc.) is open on the same serial port. Serial ports are
> exclusive — if another program is holding the port, the script cannot open it.

---

## Step 4 — Identify your serial port

### Windows

Your USB-serial adapter shows up as `COM3`, `COM4`, etc.

1. Press the **Windows key**, type `device manager`, and open it.
2. Expand **Ports (COM & LPT)**.
3. Note the name, e.g. `USB Serial Port (COM3)`. You'll pass it as
   `-ComPort COM3`.

Or, from PowerShell:

```powershell
[System.IO.Ports.SerialPort]::GetPortNames()
```

### macOS

The adapter appears as a device under `/dev/`. List the call-up devices:

```bash
ls /dev/cu.*
```

Look for something like `/dev/cu.usbserial-10` or `/dev/cu.usbserial-XXXX`.
You'll pass that full path as `-ComPort /dev/cu.usbserial-10`.

> Use the `cu.*` device, not the matching `tty.*` device, for outgoing serial
> connections.

### Linux

The adapter usually appears as `/dev/ttyUSB0` (FTDI/Prolific) or `/dev/ttyACM0`:

```bash
ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
```

Pass the full path as `-ComPort /dev/ttyUSB0`. You may need to be in the
`dialout` group (or use `sudo`) to access it.

> **Not sure which one is yours?** Unplug the adapter, run the listing command,
> plug it back in, and run it again — the device that reappears is yours.

---

## Step 5 — Edit `cimc-config.jsonc`

This is the only file you need to edit. It's plain text with comments (lines
starting with `//`) explaining each setting.

**Open it** in any text editor (Notepad, TextEdit in plain-text mode, `nano`,
or — best — VS Code, whose syntax colors help you spot typos).

### The basic rules

- Keep the quotes around text values: `"10.10.20.1"`, not `10.10.20.1`.
- Use `true` or `false` (lowercase, no quotes) for on/off switches.
- Use `null` (lowercase, no quotes) when a value is not used.
- Put a comma between items, but **no comma after the last item in a group**.
- Anything after `//` is a comment and is ignored.

### The sections

The file has four setting sections and one list of servers.

#### 5a. Site network settings (shared by every CIMC you configure with this file)

Find the `"site"` block near the top and fill in your values:

```jsonc
"site": {
    "subnetMask":     "255.255.255.0",   // subnet for the CIMC network
    "gateway":        "10.10.20.1",       // default gateway
    "nicMode":        "dedicated",        // usually "dedicated" for C-Series
    "nicRedundancy":  "none",             // usually "none"
    "vlanEnabled":    false,              // true only if your mgmt net is VLAN-tagged
    "vlanId":         0,
    "disableIpv6":    true,               // true turns IPv6 off on the CIMC mgmt interface
    "timezone":       "America/Chicago"   // Olson name: America/New_York, Europe/London, UTC, etc.
}
```

If you're unsure about `nicMode` / `nicRedundancy`, the defaults above are
correct for most C-Series deployments. Leave `disableIpv6` as `true` to disable
IPv6 (the default); set it to `false` to leave IPv6 untouched.

#### 5b. Intersight settings

```jsonc
"intersight": {
    "enableDeviceConnector": true,   // leave true
    "proxyHost":             null,    // only set if CIMC must use a proxy
    "proxyPort":             null
}
```

#### 5c. Serial port settings

The defaults match Cisco's default CIMC serial settings (`115200 / 8 / N / 1`).
Only change these if your adapter is configured differently.

```jsonc
"serial": {
    "baudRate":   115200,
    "parity":     "None",
    "dataBits":   8,
    "stopBits":   "One",
    "handshake":  "None"
}
```

#### 5d. Behavior

Timeouts. The defaults are fine for most environments.

```jsonc
"behavior": {
    "commandTimeoutSec":   20,
    "loginTimeoutSec":     60,
    "interCommandDelayMs": 250
}
```

#### 5e. The `"servers"` list — one entry per server

This is your inventory of every UCS server you plan to configure. The script
applies only the entry whose `hostName` matches the `-HostName` you pass on the
command line.

```jsonc
"servers": [

    {
        "hostName":      "rack01-ucs01",
        "ipAddress":     "10.10.20.51",
        "primaryDns":    "10.10.10.10",
        "secondaryDns":  "10.10.10.11",
        "dnsDomain":     "example.lab",
        "ntpServers": [
            "ntp1.example.lab",
            "ntp2.example.lab"
        ]
    },

    {
        "hostName":      "rack01-ucs02",
        "ipAddress":     "10.10.20.52",
        "primaryDns":    "10.10.10.10",
        "secondaryDns":  "10.10.10.11",
        "dnsDomain":     "example.lab",
        "ntpServers": [
            "ntp1.example.lab",
            "ntp2.example.lab"
        ]
    }

]
```

To add another server, copy one of the blocks (everything from `{` to `}`),
paste it below the previous one, change the values, and add a comma after the
previous block's `}`.

**Important:** the **last** server block must **not** have a trailing comma.
Example of the end of the file for three servers:

```jsonc
    },

    {
        "hostName":      "rack01-ucs03",
        "ipAddress":     "10.10.20.53",
        "primaryDns":    "10.10.10.10",
        "secondaryDns":  "10.10.10.11",
        "dnsDomain":     "example.lab",
        "ntpServers": [
            "ntp1.example.lab",
            "ntp2.example.lab"
        ]
    }

]
}
```

Notice:
- Comma **after** the second block's `}`.
- **No** comma after the third block's `}`.

Save the file when you're done.

---

## Step 6 — Run the script

Before running, confirm:

- The USB-serial adapter is plugged into your computer.
- The console cable is plugged into the UCS server's SERIAL jack.
- The UCS server has AC power.
- `cimc-config.jsonc` is edited and saved.
- You know your serial port name (from Step 4).
- No other terminal program (PuTTY, SecureCRT, `screen`, etc.) is holding the port.

### Open a terminal in the right folder

- **Windows:** in File Explorer, open the `UCS-CIMC-Config` folder, click the
  address bar, type `powershell`, and press **Enter**.
- **macOS/Linux:** open Terminal and `cd` into the folder, e.g.
  `cd ~/Desktop/UCS-CIMC-Config`, then start PowerShell with `pwsh`.

### Run it

Replace the port with your actual serial port and `rack01-ucs01` with the
`hostName` of the entry in `cimc-config.jsonc` you want to apply.

**Windows:**

```powershell
.\Configure-CIMC.ps1 -ComPort COM3 -HostName rack01-ucs01
```

**macOS/Linux:**

```bash
pwsh -NoProfile -File ./Configure-CIMC.ps1 -ComPort /dev/cu.usbserial-10 -HostName rack01-ucs01
```

Press **Enter**.

### What the script asks you

At the start of the run it asks for:

1. **CIMC password** — the password for the `admin` account **as it is today**.
   - If the server is still at factory default, type `password`.
   - If someone has already changed it, type the current password.

If — and only if — the CIMC is still at factory default, CIMC forces a password
change before it allows login. The script then prompts you for:

2. **New admin password** (only on factory-default CIMCs).
3. **Confirm new admin password** — type it again.

The text you type for passwords does not appear on screen — that's intentional.
Press **Enter** after each.

On a CIMC whose admin password has already been changed, you'll only see prompt
#1, and the script won't touch the admin password.

### The factory-default password change is automatic

After you supply the new password, CIMC briefly takes the serial console offline
while it applies the change. **You don't need to do anything** — the script
automatically re-establishes the console connection, wakes the login prompt, and
logs back in with the new password to finish the configuration.

> **After a factory reset**, the CIMC itself can take **several minutes** to
> finish booting before the serial console responds at all. The script waits and
> retries automatically (up to about 10 minutes), so a quiet
> `Probing CIMC prompt...` right after a reset is expected — just let it run.
> You do **not** need to open SecureCRT/PuTTY first.

### What you'll see while it runs

Lines starting with `->` are commands the script sent to CIMC; password lines
show `<redacted>`. A normal run on an already-booted CIMC finishes within a
minute or two (longer if it's waiting out a post-reset boot), ending with
something like:

```
Done. Log: .../logs/cimc-session-20260610-102651.log
```

If something goes wrong, the last few hundred characters CIMC sent back are
included in the error, and the full session log is saved under `logs/`.

---

## Step 7 — Claim the server in Intersight

The script doesn't print the Intersight Claim Code — grab it from the CIMC web
UI now that the CIMC has its new IP:

1. In a browser, go to `https://<the IP you just configured>` (e.g.,
   `https://10.10.20.51`). Accept the self-signed certificate warning.
2. Log in with the CIMC admin user and password.
3. Open **Admin → Device Connector** in the CIMC UI. The page shows the
   **Device ID** and a **Claim Code**.
4. In another tab, go to <https://intersight.com> and sign in.
5. **System → Targets → Claim a New Target → Cisco UCS Standalone**.
6. Paste the Device ID and Claim Code, then click **Claim**.

Within a minute or two the server appears under **Operate → Servers** in
Intersight.

You can now unplug the serial cable and move to the next server.

---

## Optional — Boot a firmware ISO (HUU) via vMedia

The script can also point the server at a firmware ISO (for example, the Cisco
**HUU** — Host Upgrade Utility) by mapping it as CIMC virtual media and putting
it first in the boot order (local LUN second), then power-cycling so the server
boots the ISO. You then complete the firmware update from the HUU screen (over
the CIMC KVM or console) — the script's job is to get the server booted to the
ISO.

### How the CIMC reaches the ISO (read this first)

The CIMC reads virtual media over its **management IP network — not over the
serial cable.** So an ISO "on your laptop" has to be served over IP, and the
CIMC must be able to reach your laptop. The recommended setup is:

- **Serial console** to the SERIAL jack (for configuration), **and**
- **Ethernet** from your laptop to the CIMC management port (so the CIMC can
  pull the ISO).

Because a direct laptop-to-CIMC Ethernet link has no DHCP, give that laptop
Ethernet interface a **static IPv4 in the CIMC's subnet**:

- Use the same subnet/mask as the CIMC (from your `"site"` settings).
- Pick a free address that is **not** the CIMC IP and **not** the gateway.
- Example: if the CIMC is `10.10.20.51 / 255.255.255.0`, set the laptop
  Ethernet to something like `10.10.20.9 / 255.255.255.0`.
- Allow inbound connections on the serve port (default `8000`) through your
  laptop's firewall.

The script auto-detects the laptop IP that is on the CIMC's subnet, so you
normally don't need to set `serveHost` — just make sure that Ethernet interface
has an address in the right subnet.

> If you can't put the laptop on the CIMC network, host the ISO on an existing
> web server instead and use `"transport": "url"` with `"shareUrl"` (below).

### Configure the `"firmware"` block

Put the ISO in a folder on your laptop, then edit the `"firmware"` block in
`cimc-config.jsonc`:

```jsonc
"firmware": {
    "enabled":        false,            // or pass -Firmware on the command line
    "transport":      "http-local",     // "http-local" serves from your laptop; "url" uses a hosted share
    "isoFolder":      "/Users/you/Desktop/firmware",
    "isoFile":        "ucs-c220m7-huu.iso",
    "serveHost":      null,              // null = auto-detect the NIC on the CIMC subnet
    "servePort":      8000,
    "shareUrl":       null,              // for transport "url", e.g. "http://10.10.10.9/iso/"
    "shareUser":      null,
    "sharePassword":  null,
    "vmediaVolume":   "firmware",
    "vmediaSubtype":  "CIMCMAPPEDDVD",   // CIMC-mapped vDVD subtype
    "dvdBootName":    "vDVD",            // boot device #1
    "localBootName":  "LocalLUN",        // boot device #2
    "localBootType":  "LOCALHDD",
    "powerCycle":     true               // power-cycle to boot the ISO
}
```

### Run it

Enable the firmware step either by setting `"enabled": true`, or by adding
`-Firmware` (with optional `-IsoFolder` / `-IsoFile` overrides) to the normal
run command:

```bash
pwsh -NoProfile -File ./Configure-CIMC.ps1 -ComPort /dev/cu.usbserial-10 -HostName rack01-ucs01 \
    -Firmware -IsoFolder ~/Desktop/firmware -IsoFile ucs-c220m7-huu.iso
```

On Windows:

```powershell
.\Configure-CIMC.ps1 -ComPort COM3 -HostName rack01-ucs01 -Firmware -IsoFolder C:\firmware -IsoFile ucs-c220m7-huu.iso
```

The script maps the ISO, verifies the mapping status, sets the boot order,
power-cycles the server, and then **keeps the local HTTP server running** while
the CIMC reads the media. **Leave the script window open** until the firmware
update is finished — press **Enter** in the script only when you're done, which
stops serving the ISO.

> **Note:** the exact CIMC CLI tokens for the vMedia boot subtype, the local
> LUN device type, and the power-cycle command can vary by firmware version. If
> the log shows one of these was rejected, adjust `vmediaSubtype`,
> `localBootType`, etc. in the `"firmware"` block and re-run. The session log
> under `logs/` records exactly what the CIMC returned.

---

## Troubleshooting

### "The term '.\Configure-CIMC.ps1' is not recognized" / "command not found"

You're not in the right folder, or (macOS/Linux) you didn't prefix the command
with `pwsh -File`. Re-read **Step 6 — Open a terminal in the right folder** and
use the correct command for your OS.

### "... cannot be loaded because running scripts is disabled on this system" (Windows)

You skipped the execution-policy step. Run this once, then press **Y**:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

### "COM port 'COM3' not found" / device path doesn't exist

- The USB-serial adapter isn't plugged in, or the system assigned it a
  different name. Repeat **Step 4** and use the exact name/path.
- macOS: confirm with `ls /dev/cu.*`; Linux: `ls /dev/ttyUSB*`.

### "Access to the port is denied" / "Resource busy"

Another program (PuTTY, SecureCRT, Tera Term, `screen`, etc.) is holding the
serial port. Close it and try again. Only one program can use the port at a time.

### Script sits at "Probing CIMC prompt..." or "Console still offline..."

- **Right after a factory reset this is normal** — the CIMC is still booting and
  can take several minutes. The script keeps retrying automatically; let it run.
- If it never connects: check the cable is fully seated in the **SERIAL** /
  **CONSOLE** jack (not the management Ethernet port), the serial settings match
  (`115200 / 8 / N / 1`, the defaults), and that no other terminal program is
  holding the port.

### "Authentication failed with both supplied and factory-default passwords"

Someone has already changed the CIMC admin password to something other than
`password`, and the value you typed was wrong. Run again with the correct
current password.

### "Failed to parse JSON config"

You made a typo in `cimc-config.jsonc`. Usually it's:

- A missing quote — `"10.10.20.1` with no closing `"`.
- A missing comma between two server blocks.
- A **trailing** comma after the last server block.
- Unbalanced brackets — every `{` needs a matching `}`, every `[` needs a `]`.

Open the file in VS Code if you have it — it highlights the broken line.

### "hostName 'x' not found in config"

The `-HostName` you passed doesn't match any `hostName` in the JSON file.
Spelling and case don't matter, but spaces do. Re-check the `"hostName"` values
in your `"servers"` list.

### I broke the JSON file and can't fix it

No worries. Grab a fresh copy of `cimc-config.jsonc` from the original repo and
start over.

---

## Glossary

- **CIMC** — Cisco Integrated Management Controller. The small computer inside a
  UCS server that manages it.
- **Intersight** — Cisco's cloud management portal.
- **Serial port / COM port** — a serial connection. On Windows it's named
  `COM3`, etc.; on macOS it's a `/dev/cu.usbserial-*` path; on Linux it's
  `/dev/ttyUSB*` or `/dev/ttyACM*`. Your USB-serial adapter becomes one of these
  when you plug it in.
- **Serial console** — a text-only connection over a serial cable. No mouse, no
  graphics — just text.
- **Baud rate** — the speed of a serial connection. Cisco CIMC uses 115200 baud.
- **NIC mode** — which physical network port CIMC uses. `dedicated` means the
  small dedicated management port on the back.
- **NIC redundancy** — whether CIMC uses more than one port at once. `none`
  means a single port.
- **NTP** — Network Time Protocol. Keeps the server's clock correct.
- **DNS** — Domain Name System. Translates names like `intersight.com` into IP
  addresses.
- **JSONC** — JSON with comments. A forgiving version of JSON you can add `//`
  notes to.
