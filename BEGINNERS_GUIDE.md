# Beginner's Guide: Configuring a Cisco UCS C-Series Server (CIMC) Over Serial

This guide walks you through configuring the CIMC (the management controller)
on a Cisco UCS C-Series server, step by step, from an empty laptop.

No prior PowerShell or networking-tool experience required. If you can open a
text file and type a command in a terminal window, you can do this.

The script configures **one server at a time** over a single serial connection.
You can keep an inventory of every server you'll eventually configure in
`cimc-config.jsonc` and run the script once per server.

---

## Table of Contents

1. [What you're going to do](#1-what-youre-going-to-do)
2. [What you need](#2-what-you-need)
3. [Step 1 — Get the files onto your laptop](#step-1--get-the-files-onto-your-laptop)
4. [Step 2 — Make sure PowerShell is installed](#step-2--make-sure-powershell-is-installed)
5. [Step 3 — Connect your laptop to the UCS server](#step-3--connect-your-laptop-to-the-ucs-server)
6. [Step 4 — Find your COM port number](#step-4--find-your-com-port-number)
7. [Step 5 — Edit `cimc-config.jsonc`](#step-5--edit-cimc-configjsonc)
8. [Step 6 — Run the script](#step-6--run-the-script)
9. [Step 7 — Claim the server in Intersight](#step-7--claim-the-server-in-intersight)
10. [Troubleshooting](#troubleshooting)
11. [Glossary](#glossary)

---

## 1. What you're going to do

Every UCS C-Series server has a small management computer inside it called
**CIMC** (Cisco Integrated Management Controller). It has its own IP address,
hostname, DNS, NTP, and password — completely separate from the operating
system that runs on the server.

Out of the factory, CIMC has no static IP address. Before the server can be
managed by **Intersight** (Cisco's cloud management portal), you have to log
into CIMC once and give it that information.

You're going to do that by:

1. Plugging a serial cable from your laptop to the back of the UCS server.
2. Running a PowerShell script on your laptop.
3. The script logs into CIMC over the serial cable and configures everything
   for you.

When the script finishes, the CIMC is reachable on its new IP address. You
then open the CIMC web UI in a browser and grab the Device ID and Claim Code
to register the server with Intersight.

---

## 2. What you need

### Hardware

- A Windows laptop
- A **USB-to-Serial adapter** (e.g., a generic FTDI or Prolific USB-serial cable)
- A **Cisco RJ-45 serial console cable**, or an RJ-45 to DB-9 (female) cable
  — this is the same style of cable used for switch/router console ports
- Access to the **back** of the UCS C-Series server

On the back of a UCS C220/C240, look for a connector labeled **SERIAL** or
**CONSOLE**. It's an RJ-45 jack (looks like an Ethernet port) usually near the
management ports. Do **not** use the "Management" Ethernet port for this — we
want the serial jack specifically.

### Software (all free)

- **Windows 10 or 11** (or Windows Server). PowerShell 5.1 is already built in.
- Optional but nicer: **PowerShell 7** and **Visual Studio Code**.

### Information from your network team

Before you start, ask your network team for:

| Item                                   | Example             |
|----------------------------------------|---------------------|
| The static IP for the CIMC             | `10.10.20.51`       |
| Subnet mask                            | `255.255.255.0`     |
| Default gateway                        | `10.10.20.1`        |
| Primary DNS server                     | `10.10.10.10`       |
| Secondary DNS server (if any)          | `10.10.10.11`       |
| DNS domain name                        | `example.lab`       |
| NTP server(s)                          | `ntp1.example.lab`  |
| The hostname you want for the server   | `rack01-ucs01`      |
| VLAN ID for the management network (if tagged) | usually none |

You only need a **new CIMC admin password** if the CIMC is still at its
factory default (`admin / password`). In that case CIMC will force a password
change at first login, and the script will prompt you for the new password
right then. On a CIMC whose password has already been changed, the script
will not ask about the password at all (other than the current one to log
in).

---

## Step 1 — Get the files onto your laptop

1. Copy the whole `UCS-CIMC-Config` folder to your laptop. A good place is
   `C:\Users\<your-name>\Desktop\UCS-CIMC-Config`.
2. Open that folder. You should see:
   - `Configure-CIMC.ps1`
   - `cimc-config.jsonc`
   - `README.md`
   - `BEGINNERS_GUIDE.md` (this file)

Do **not** rename or delete any of these files.

---

## Step 2 — Make sure PowerShell is installed

Windows already has PowerShell 5.1. You do not need to install anything to run
the script.

### How to open PowerShell

1. Press the **Windows key**.
2. Type `powershell`.
3. Click **Windows PowerShell** in the results.

A blue window with a `PS C:\Users\...>` prompt appears. This is where you will
run the script.

### One-time: allow the script to run

Windows blocks downloaded scripts by default. To let this one run, type:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Press **Enter**, then **Y** to confirm. You only need to do this once on your
laptop.

---

## Step 3 — Connect your laptop to the UCS server

1. Plug the USB end of your USB-to-Serial adapter into your laptop.
   - Windows should install a driver automatically. If it doesn't, install the
     driver from the adapter's manufacturer (FTDI, Prolific, etc.).
2. Plug the RJ-45 end of the console cable into the **SERIAL** (or **CONSOLE**)
   jack on the back of the UCS server.
3. Plug the other end of the console cable into your USB-to-Serial adapter.
4. Make sure the UCS server is **powered on** — press the power button on the
   front. You don't need to wait for anything to "boot"; CIMC is available as
   soon as the server has AC power.

That's it for the physical setup.

> **Tip:** if you're going to configure several servers from a cart, you can
> keep your laptop and adapter on the cart and just move the RJ-45 end between
> server serial jacks, running the script once per server.

> **Important:** make sure no other terminal program (PuTTY, SecureCRT, Tera
> Term, etc.) is currently open on the same COM port. Windows COM ports are
> exclusive — if PuTTY is holding the port, the script will fail to open it.

---

## Step 4 — Find your COM port number

Your USB-serial adapter shows up in Windows as `COM3`, `COM4`, etc. You need
to know which one.

### Easiest way — Device Manager

1. Press the **Windows key**, type `device manager`, and open it.
2. Expand **Ports (COM & LPT)**.
3. You should see something like:
   `USB Serial Port (COM3)` or `Prolific USB-to-Serial Comm Port (COM5)`.
4. Write down the number in parentheses — e.g., **`COM3`**. You'll pass it to
   the script with `-ComPort COM3`.

### From PowerShell

You can also list available COM ports by typing this in PowerShell:

```powershell
[System.IO.Ports.SerialPort]::GetPortNames()
```

You'll see something like:

```
COM3
```

If you see several names, try unplugging the USB-serial adapter and running
the command again — the one that disappears is yours.

---

## Step 5 — Edit `cimc-config.jsonc`

This is the only file you need to edit. It's a plain text file with comments
(green lines starting with `//`) that explain each setting.

### Open it

Right-click `cimc-config.jsonc` → **Open with** → **Notepad**.

(If you have VS Code, it's even nicer — syntax colors help you spot typos.)

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
    "subnetMask":     "255.255.255.0",   // <-- subnet for the CIMC network
    "gateway":        "10.10.20.1",       // <-- default gateway
    "nicMode":        "dedicated",        // usually "dedicated" for C-Series
    "nicRedundancy":  "none",             // usually "none"
    "vlanEnabled":    false,              // true only if your mgmt net is VLAN-tagged
    "vlanId":         0,
    "timezone":       "America/Chicago"   // Olson name: America/New_York, Europe/London, UTC, etc.
}
```

If you're not sure about `nicMode` / `nicRedundancy`, the defaults above are
correct for most C-Series deployments.

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
Only change these if your adapter is set up differently.

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

Timeouts. The defaults are fine.

```jsonc
"behavior": {
    "commandTimeoutSec":   20,
    "loginTimeoutSec":     60,
    "interCommandDelayMs": 250
}
```

#### 5e. The `"servers"` list — one entry per server

This is where you keep the inventory of every UCS server you plan to
configure. The script will look up the entry whose `hostName` matches the
`-HostName` you pass on the command line and apply only that one.

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

**Very important:** the **last** server block must **not** have a trailing
comma. Example of the end of the file for three servers:

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

Save the file when you're done (**Ctrl+S** in Notepad).

---

## Step 6 — Run the script

You should have:
- Your USB-serial adapter plugged into the laptop.
- The console cable plugged into the UCS server's SERIAL jack.
- The UCS server powered on.
- `cimc-config.jsonc` edited and saved.
- The COM port number (from Step 4).
- Any other terminal program (PuTTY, SecureCRT, etc.) closed on that COM port.

### Open a PowerShell prompt *in the right folder*

1. In File Explorer, open the `UCS-CIMC-Config` folder.
2. Click the address bar at the top.
3. Type `powershell` and press **Enter**.

A PowerShell window opens with its current folder already set correctly.

### Run it

Type the command (replace `COM3` with your actual COM port and
`rack01-ucs01` with the `hostName` of the entry in `cimc-config.jsonc` you
want to apply):

```powershell
.\Configure-CIMC.ps1 -ComPort COM3 -HostName rack01-ucs01
```

Press **Enter**.

### What the script asks you

At the start of the run it asks for:

1. **CIMC password** — the password for the `admin` account **as it is today**.
   - If the server is still at factory default, type `password`.
   - If someone has already changed it, type the current password.

If — and only if — the CIMC is still at factory default, CIMC will force a
password change before it lets the script log in. At that moment the script
will pause and ask you for:

2. **New admin password** (you'll only see this prompt on factory-default
   CIMCs).
3. **Confirm new admin password** — type it again.

The text won't appear on screen when you type it — that's normal and is there
to keep it private. Press **Enter** after each.

On a CIMC whose admin password has already been changed from the factory
default, you will only see prompt #1 above and the script will not touch the
admin password.

### What you'll see while it runs

Cyan lines starting with `->` are commands the script sent to CIMC. Password
lines show `<redacted>`. The run typically finishes within a minute or two,
ending with something like:

```
Done. Log: C:\...\logs\cimc-session-20260427-110501.log
```

If anything went wrong, the last few hundred characters the CIMC sent back are
included in the error so you can spot the problem in the session log.

---

## Step 7 — Claim the server in Intersight

The script doesn't print the Intersight Claim Code — grab it from the CIMC
web UI now that the CIMC has its new IP:

1. In a web browser, go to `https://<the IP you just configured>` (e.g.,
   `https://10.10.20.51`). Accept the self-signed certificate warning.
2. Log in with the CIMC admin user and password.
3. Open **Admin** → **Device Connector** in the CIMC UI. The page shows the
   **Device ID** and a **Claim Code**.
4. In another tab, go to <https://intersight.com> and sign in.
5. **System** → **Targets** → **Claim a New Target** → **Cisco UCS Standalone**.
6. Paste the Device ID and Claim Code, then click **Claim**.

Within a minute or two the server appears under **Operate → Servers** in
Intersight.

You can now unplug the serial cable and move to the next server.

---

## Troubleshooting

### "The term '.\Configure-CIMC.ps1' is not recognized"

You're not in the right folder. Close PowerShell and repeat **Step 6 — Open a
PowerShell prompt *in the right folder***.

### "... cannot be loaded because running scripts is disabled on this system"

You skipped the execution-policy step. Run this once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Then press **Y** to confirm.

### "COM port 'COM3' not found"

- Your USB-serial adapter isn't plugged in, or Windows gave it a different
  number.
- Repeat **Step 4** and use the right COM name.

### "Access to the port 'COMx' is denied"

Another program (PuTTY, SecureCRT, Tera Term, screen, the Windows printer
spooler, etc.) is holding the COM port. Close it and try again.

### "Timeout waiting for pattern(s): login:"

- The serial cable isn't fully seated, or you're plugged into the wrong jack
  (check it's **SERIAL** / **CONSOLE**, not the management Ethernet port).
- The adapter's baud rate doesn't match. The defaults in `cimc-config.jsonc`
  (`115200 / 8 / N / 1`) are correct for Cisco CIMC.
- The server has no AC power.

### "Failed to parse JSON config"

You made a typo in `cimc-config.jsonc`. Usually it's:

- A missing quote — `"10.10.20.1` with no closing `"`.
- A missing comma between two server blocks.
- A **trailing** comma after the last server block.
- Unbalanced brackets — every `{` needs a matching `}`, every `[` needs a `]`.

Open the file in VS Code if you have it — it will highlight the broken line.

### "hostName 'x' not found in config"

The `-HostName` you passed doesn't match any `hostName` in the JSON file.
Spelling and case don't matter, but spaces do. Re-check the `"hostName"`
values in your `"servers"` list.

### "Authentication failed with both supplied and factory-default passwords"

Somebody has already changed the CIMC admin password to something other than
`password`, and what you typed at the prompt was wrong. Try again with the
correct current password.

### The script hangs after "Probing CIMC prompt..."

- Almost always a cable or COM-port issue. Unplug the USB-serial adapter,
  plug it back in, re-check the COM number, and run again.
- If you can see a CIMC banner in PuTTY but not via the script, make sure
  PuTTY is closed first (only one program can hold a COM port).

### I broke the JSON file and can't fix it

No worries. Grab a fresh copy of `cimc-config.jsonc` from the original repo
and start over.

---

## Glossary

- **CIMC** — Cisco Integrated Management Controller. The tiny computer inside
  a UCS server that manages it.
- **Intersight** — Cisco's cloud management portal.
- **COM port** — the name Windows uses for a serial port. Your USB-serial
  adapter becomes a COM port when you plug it in.
- **Serial console** — a text-only connection over a serial cable. No mouse,
  no graphics. Just text.
- **Baud rate** — the speed of a serial connection. Cisco CIMC uses 115200
  baud.
- **NIC mode** — which physical network port on the server CIMC uses.
  `dedicated` means the small dedicated management port on the back.
- **NIC redundancy** — whether CIMC uses more than one port at once. `none`
  means a single port.
- **NTP** — Network Time Protocol. Makes sure the server's clock is correct.
- **DNS** — Domain Name System. Translates `intersight.com` into an IP address.
- **JSONC** — JSON with comments. A forgiving version of JSON you can add
  `//` notes to.
