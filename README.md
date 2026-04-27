# UCS C-Series CIMC Configuration (Serial)

PowerShell script that drives the CIMC CLI over the serial console to configure
networking, DNS, NTP, hostname, NIC mode/redundancy, and to enable the
Intersight Device Connector so the server is ready to claim in Intersight.

The script configures **one server at a time** over a single COM port. All
editable values live in a single **JSONC** file (`cimc-config.jsonc`). JSONC is
JSON plus comments — open it in Notepad, VS Code, or any text editor.

> **First time using this?** Start with **[`BEGINNERS_GUIDE.md`](./BEGINNERS_GUIDE.md)**.
> It walks you through connecting the serial cable, finding your COM port,
> editing the JSON file, and running the script step by step.

## Files

| File                    | What it is                                                                                  |
|-------------------------|---------------------------------------------------------------------------------------------|
| `Configure-CIMC.ps1`    | The script. You do not need to open this to run a deployment.                               |
| `cimc-config.jsonc`     | The only file you edit. Site settings + an inventory of server entries.                     |
| `logs/`                 | Timestamped session logs (auto-created on first run).                                       |

## What the script does on the connected server

- Logs in over the serial console (handles the forced first-login password
  change automatically when CIMC is at factory default).
- NIC mode (`dedicated` / `shared_lom*` / `cisco_card`) and redundancy.
- Static IPv4 (address, subnet mask, gateway).
- DNS (primary + optional secondary) and DNS domain.
- Hostname (CIMC will also auto-regenerate its self-signed certificate with the
  new hostname as CN — the script answers that prompt for you).
- Up to 4 NTP servers + timezone (NTP service is enabled and committed before
  the server addresses are loaded, so the entries actually take effect).
- Optional VLAN tagging on the management port.
- Enables the Intersight Device Connector (and proxy, if configured).

The script **only changes the CIMC admin password** when the CIMC is still at
its factory default and CIMC itself forces a change at first login. On a CIMC
that already has a non-default password, the script never prompts for a new
password and never changes it.

## Requirements

- Windows with PowerShell 5.1 or PowerShell 7+.
- USB-to-serial adapter connected to the CIMC serial port (the rear console
  jack on most C-Series).
- Serial settings: `115200 / 8 / N / 1`, no flow control. These are CIMC
  factory defaults and are also the JSON file's defaults.

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
| `Timeout waiting for pattern(s): login:`                      | Baud rate / wiring / wrong physical port (use the rear console jack). |
| Script appears stuck at "Probing CIMC prompt..."              | Another app (PuTTY / SecureCRT / Tera Term) has the COM port open.    |
| `Authentication failed with both supplied and factory-default passwords` | Someone has changed the CIMC password and the value typed at the prompt is wrong. |
| `Invalid scope` on `scope cloud` / `scope device-connector`   | Very old CIMC firmware — upgrade it and retry.                        |
| `active-active` rejected                                      | Only valid with a `shared_lom*` NIC mode. Use `none` with `dedicated`. |
| `Network commit did not return to CLI prompt …`               | CIMC produced an unexpected confirmation prompt; check the session log under `logs/` for the last RX. |
