# Now-SDK Quickstart

![Windows 10 | 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?logo=windows&logoColor=white)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
![No admin rights](https://img.shields.io/badge/admin%20rights-not%20required-2ea44f)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Set up the [ServiceNow SDK](https://www.npmjs.com/package/@servicenow/sdk) (`now-sdk`) on
Windows and connect it to your instance with OAuth, **without admin rights**.

> [!NOTE]
> This is a community tool, not affiliated with or supported by ServiceNow. It installs the
> official `@servicenow/sdk` package from npm and uses the SDK's own sign-in.

<!-- Add a screenshot or GIF of the setup window here, e.g.:
![Now-SDK Quickstart setup window](docs/screenshot.png)
-->

## Quick start

1. **Download:** click **Code > Download ZIP**, then unblock and extract it (see below).
2. **Run:** double-click `Setup-ServiceNowSDK.cmd` and enter your instance URL.
3. **Sign in:** use the browser window that opens, then paste the code it shows into the
   console window.

Then open a **new** terminal and run `now-sdk --help`.

> [!IMPORTANT]
> Before extracting the zip, right-click it, choose **Properties**, tick **Unblock**, and
> click **OK**. Don't run the tool from inside the zip. If Windows SmartScreen appears, click
> **More info > Run anyway**.

## What it does

1. **Checks** that your instance is reachable, and warns you if a developer instance is
   hibernating.
2. **Finds Node.js 20.18+.** If none is found, it downloads the official portable Node.js
   and verifies it against its SHA-256 checksum.
3. **Installs** `@servicenow/sdk`, pinned to a tested version.
4. **Adds** the SDK to your **user** PATH.
5. **Checks** that Windows Credential Manager has room for the sign-in.
6. **Signs you in** with the SDK's OAuth flow: log in through the browser, then paste the
   code.
7. **Verifies** the saved connection by calling your instance's REST API.

Running it again is safe. It skips anything already installed and asks before replacing a
saved connection.

## Requirements

- Windows 10 (1803 or later) or Windows 11, using the built-in Windows PowerShell 5.1
- Internet access to `nodejs.org`, `registry.npmjs.org` and your instance
- An instance with the **ServiceNow IDE Runtime Services** plugin active (see
  [For instance admins](#for-instance-admins))

## What it changes on your computer

All changes are for your Windows account only.

| What | Where |
|---|---|
| Node.js (**only if** you don't already have 20.18+) | `%LOCALAPPDATA%\Programs\nodejs` |
| ServiceNow SDK | Next to that portable Node.js, or else npm's user folder (`%APPDATA%\npm`) |
| User PATH | The folder(s) above |
| OAuth tokens | Windows Credential Manager (stored by the SDK) |
| Log | `%LOCALAPPDATA%\ServiceNowSdkSetup\setup.log` |

<details>
<summary><b>Command-line options</b></summary>

```
Setup-ServiceNowSDK.cmd [-InstanceUrl <url>] [-Alias <name>] [-NoGui] [-Force] [-NoDefault]
                        [-SdkVersion <version>] [-NodeDir <folder>]
```

| Option | Meaning |
|---|---|
| `-InstanceUrl`, `-Alias` | Skip the input dialog. |
| `-NoGui` | Use console prompts instead of dialog windows. |
| `-Force` | Sign in again even if the alias already exists. |
| `-NoDefault` | Don't make this the SDK's default connection. |
| `-SdkVersion` | SDK version to install (defaults to the tested version). |
| `-NodeDir` | Where to put portable Node.js (default `%LOCALAPPDATA%\Programs\nodejs`). |

Example:

```
Setup-ServiceNowSDK.cmd -InstanceUrl https://acme.service-now.com -Alias acme -NoGui
```

</details>

## Troubleshooting

<details>
<summary><b>"Windows Credential Manager is full" / "Platform secure storage failure: Windows error code 8"</b></summary>

Windows limits the total size of your saved credentials. The Xbox app often fills it with
hundreds of `XblGrts` entries, which is a known Windows issue. Windows recreates them when
needed.

To delete them (no admin needed), run this in PowerShell, then run setup again:

```powershell
cmdkey /list | Select-String 'target=(XblGrts\|\S+)' | ForEach-Object { cmdkey "/delete:$($_.Matches[0].Groups[1].Value)" | Out-Null }
```

> [!TIP]
> The Xbox app or games may ask you to sign in again afterwards. If the entries build up
> again, re-run the command.

</details>

<details>
<summary><b>"Sign-in did not complete" or the token is rejected</b></summary>

The instance must have the SDK's OAuth app. Send your admin to
[For instance admins](#for-instance-admins).

</details>

<details>
<summary><b>"Your developer instance appears to be hibernating"</b></summary>

Wake it up at [developer.servicenow.com](https://developer.servicenow.com), wait until it's
running, then run setup again.

</details>

<details>
<summary><b>"Windows blocked Node.js from running"</b></summary>

Your organization's AppLocker or WDAC policy only allows approved programs. Install
Node.js 20.18+ from Company Portal / Software Center, or ask IT to allow it, then run setup
again. It will use that Node.js.

</details>

<details>
<summary><b>No dialog windows, only console prompts</b></summary>

PowerShell is in Constrained Language Mode because of an application control policy. Setup
still works; it just uses the console instead of dialog windows.

</details>

<details>
<summary><b><code>node</code> in a new terminal shows an old version</b></summary>

An older Node.js installed by an administrator comes first on the system PATH. `now-sdk`
still uses the correct Node.js, so you can ignore this unless you need `node` itself.

</details>

<details>
<summary><b><code>now-sdk</code> is not found</b></summary>

Open a new terminal window, or sign out of Windows and back in.

</details>

## Uninstall

<details>
<summary><b>Steps</b></summary>

1. Remove the saved connection with `now-sdk auth --delete <alias>`, or delete it in
   *Credential Manager > Windows Credentials*.
2. Delete `%LOCALAPPDATA%\Programs\nodejs` if setup installed it. Otherwise run
   `npm uninstall -g @servicenow/sdk`.
3. Remove the added folders from your user PATH: *Settings > System > About > Advanced
   system settings > Environment Variables > User variables > Path*.
4. Delete `%LOCALAPPDATA%\ServiceNowSdkSetup` (logs).

</details>

## For instance admins

The SDK signs in with the out-of-box OAuth application **"ServiceNow SDK"**:

| Setting | Value |
|---|---|
| Client ID | `543e5655f77746a28228c6009a599dfb` |
| Client type | Public, authorization code with PKCE |
| Redirect URL | `/sdk-oauth.do` |
| Delivered by | **ServiceNow IDE Runtime Services** plugin (`com.glide.ide`) |

If users can't sign in:

1. Check that the plugin is active.
2. Check that *System OAuth > Application Registry* has an **active** "ServiceNow SDK" record.


## Privacy and security

- The log never contains passwords or tokens. It does include your instance URL, alias,
  Windows username and install paths, so check it before you share it.
- Node.js is downloaded only from `nodejs.org` and checked against the official SHA-256
  list. The SDK comes from the public npm registry, pinned to a tested version.
- The OAuth app record in `admin/` holds no secret: "ServiceNow SDK" is a public client.

## Updating the SDK version

The script installs a pinned SDK version (`$SdkVersion` at the top of
`Setup-ServiceNowSDK.ps1`). To try a newer one, run
`Setup-ServiceNowSDK.cmd -SdkVersion <version>`. Once you've tested it, change the default.

## License

[MIT](LICENSE)
