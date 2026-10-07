# UCS C-Series CIMC Configuration (Serial)

PowerShell script that drives the CIMC CLI over the serial console. It sets
networking, DNS, NTP, hostname, and the Intersight Device Connector. With the
firmware step on, it serves a Host Upgrade Utility ISO and has CIMC update and
activate every component. CIMC boots that ISO as part of the upgrade.

The script configures **one server at a time** over a single serial port. All
editable values live in a single **JSONC** file (`cimc-config.jsonc`). JSONC is
JSON plus comments — open it in Notepad, VS Code, or any text editor.

> **First time using this?** Start with **[`DEPLOYMENT_GUIDE.md`](./DEPLOYMENT_GUIDE.md)**.
> It walks you through connecting the serial cable, identifying your serial port
> (Windows/macOS/Linux), editing the JSON file, running the script, and the
> optional firmware upgrade.

## Files

| File                    | What it is                                                                                  |
|-------------------------|---------------------------------------------------------------------------------------------|
| `Configure-CIMC.ps1`    | The script. You do not need to open this to run a deployment.                               |
| `cimc-config.jsonc`     | The only file you edit. Site settings, server inventory, optional firmware block.           |
| `DEPLOYMENT_GUIDE.md`   | Step-by-step operator walkthrough (serial, config, Intersight claim, firmware).             |
| `logs/`                 | Timestamped session logs (auto-created on first run).                                       |

## What the script does on the connected server

In this order:

1. Log in. On a factory-default CIMC, complete the forced password change.
2. Set NIC mode, static IPv4, DNS, hostname, and DNS domain. A hostname change
   regenerates the CIMC certificate. The script answers that prompt.
3. Enable NTP, then load up to four NTP servers and the timezone.
4. Enable the Intersight Device Connector, and a proxy if one is configured.
5. If `firmware.enabled` is true, or you pass `-Firmware`, run the HUU upgrade.
   CIMC mounts the ISO, updates and activates every component, then the script
   puts the boot drive first. If the automatic job cannot start, the script
   maps the ISO and boots it so you can choose Update and Activate on the HUU screen.

`site.disableIpv6` turns IPv6 off on the management port. `site.vlanEnabled`
tags that port. CIMC settings apply when they are committed, so the script does
not reboot the host after a configuration-only run.

The script **only changes the CIMC admin password** when the CIMC is still at
its factory default and CIMC itself forces a change at first login. On a CIMC
that already has a non-default password, the script never prompts for a new
password and never changes it.

## Requirements

- Windows with PowerShell 5.1+, or macOS/Linux with PowerShell 7+ (`pwsh`).
- USB-to-serial adapter connected to the CIMC serial port (the rear **SERIAL**
  / **CONSOLE** jack on most C-Series).
- Serial settings: `115200 / 8 / N / 1`, no flow control. These are CIMC
  factory defaults and are also the JSON file's defaults.
- For the optional firmware step:
  - Ethernet from the laptop to the CIMC management port. CIMC reads the ISO
    over that network, not over serial.
  - A static IPv4 on that Ethernet NIC in the CIMC subnet.
  - Python 3 when `firmware.transport` is `"http-local"`.

## Editing `cimc-config.jsonc`

The file is heavily commented with instructions next to each value. The rules
to remember:

- Keep the quotes around text values: `"10.10.20.1"`, not `10.10.20.1`.
- Use `true` or `false` (lowercase, no quotes) for on/off switches.
- Use `null` (lowercase, no quotes) to mean "not set".
- Put commas between items, but **no comma after the last item**.
- Anything after `//` on a line is a comment and is ignored. `/* ... */`
  blocks are also comments.

The parser tolerates trailing commas, but sticking to the "no trailing comma"
rule keeps the file valid for every JSON editor.

### Adding a new server entry

You can keep an inventory of every server you'll eventually configure in the
`servers` array. Copy one of the existing entries, paste it, and change the
values. Example minimal entry:

```jsonc
{
    "hostName":      "rack02-ucs01",
    "ipAddress":     "10.10.20.61",
    "primaryDns":    "10.10.10.10",
    "secondaryDns":  "10.10.10.11",      // "" if not used
    "dnsDomain":     "example.lab",
    "ntpServers": [
        "ntp1.example.lab",
        "ntp2.example.lab"
    ]
}
```

When you run the script with `-HostName rack02-ucs01`, that one entry is the
one applied to the CIMC currently attached to `-ComPort`.

## Running the script

The script always operates on **one** CIMC at a time — the one currently
attached to `-ComPort`. The `-HostName` argument tells the script which entry
in `cimc-config.jsonc` to apply.

```powershell
.\Configure-CIMC.ps1 -ComPort COM3 -HostName rack01-ucs01
```

macOS / Linux:

```bash
pwsh -NoProfile -File ./Configure-CIMC.ps1 -ComPort /dev/cu.usbserial-10 -HostName rack01-ucs01
```

## Firmware upgrade (optional)

Turn it on with `-Firmware`, or set `"firmware"."enabled"` to `true`. The ISO
is `firmware.isoFolder` / `-IsoFolder` plus `firmware.isoFile` / `-IsoFile`.

CIMC pulls the ISO over its management IP. Use the serial cable for the script
and an Ethernet cable from the laptop to the CIMC management port. Give that
Ethernet NIC a static IPv4 in the CIMC subnet, and allow inbound TCP
`firmware.servePort` (default `8000`). Leave `serveHost` null unless you need
to override the auto-detected address. `"http-local"` serves the folder from
the laptop. `"url"` uses a pre-hosted `shareUrl`.

```powershell
.\Configure-CIMC.ps1 -ComPort COM3 -HostName rack01-ucs01 -Firmware -IsoFolder C:\firmware -IsoFile ucs-c220m7-huu.iso
```

```bash
pwsh -NoProfile -File ./Configure-CIMC.ps1 -ComPort /dev/cu.usbserial-10 -HostName rack01-ucs01 \
    -Firmware -IsoFolder ~/Desktop/firmware -IsoFile ucs-c220m7-huu.iso
```

Leave the window open until the log says the job finished. The HTTP server
stops after that. `updateComponent` defaults to `all,hdd` (every component,
including drives). Use `all` to skip drives. A full run often takes one to
three hours.

If CIMC rejects the automatic job, the script maps the ISO, sets the boot order
to KVM DVD, CIMC vDVD, the boot drive, then the UEFI shell, and power-cycles.
Finish Update and Activate on the HUU screen, then press Enter in the script.
Operator steps are in [`DEPLOYMENT_GUIDE.md`](./DEPLOYMENT_GUIDE.md).

## Credentials are never stored in the file

When the script starts it prompts (as hidden input) for:

1. The **current** CIMC admin password (to log in with). On a brand-new
   factory-default CIMC type `password` (the Cisco default).
2. **Only if the CIMC is at factory default** and CIMC's first-login flow
   forces a change: the script will then prompt for a new admin password and
   ask you to confirm it. On any other CIMC this prompt is skipped entirely.

Passwords are never written to `cimc-config.jsonc` and never appear in the log.

## Intersight claim

The script enables the Device Connector and commits the configuration. To
claim the server in Intersight, browse to the CIMC web UI at the IP you just
configured, open **Admin → Device Connector**, and copy the Device ID and
Claim Code shown there into Intersight: **Targets → Claim a New Target → Cisco
UCS Standalone**.

## Troubleshooting

| Symptom                                                       | Likely cause                                                          |
|---------------------------------------------------------------|-----------------------------------------------------------------------|
| `Config file not found`                                       | The JSON file isn't sitting next to the script, or `-ConfigPath` typo. |
| `Failed to parse JSON config`                                 | Check for a missing quote, missing comma, or a stray trailing comma.  |
| `hostName 'x' not found in config`                            | The `-HostName` argument doesn't match any `hostName` in the JSON.    |
| `COM port 'COMx' not found`                                   | Check Device Manager for the adapter's COM number.                    |
| `Timeout waiting for pattern(s): login:`                      | Baud rate / wiring / wrong physical port (use the rear console jack). After a factory reset, wait — CIMC boot can take several minutes. |
| Script appears stuck at "Probing CIMC prompt..."              | Another app (PuTTY / SecureCRT / Tera Term / `screen`) has the serial port open, or CIMC is still booting. |
| HUU job does not start, or the ISO never downloads           | Laptop Ethernet is not on the CIMC subnet, the firewall blocks `servePort`, the ISO name is wrong, or Python is not installed. |
| `create-boot-device` / `set subtype` / `power cycle` rejected | Automatic HUU did not start, and a fallback boot token was rejected. Adjust the names in the `"firmware"` block and retry. |
| `Authentication failed with both supplied and factory-default passwords` | Someone has changed the CIMC password and the value typed at the prompt is wrong. |
| `Invalid scope` on `scope cloud` / `scope device-connector`   | Very old CIMC firmware — upgrade it and retry.                        |
| `active-active` rejected                                      | Only valid with a `shared_lom*` NIC mode. Use `none` with `dedicated`. |
| `Network commit did not return to CLI prompt …`               | CIMC produced an unexpected confirmation prompt; check the session log under `logs/` for the last RX. |
