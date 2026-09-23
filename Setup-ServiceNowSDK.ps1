#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the ServiceNow SDK for the current Windows user (no admin rights) and
    connects it to a ServiceNow instance using OAuth.

.DESCRIPTION
    1. Checks that the instance is reachable.
    2. Finds Node.js >= 20.18, or downloads a portable copy into
       %LOCALAPPDATA%\Programs\nodejs (SHA-256 verified).
    3. Installs @servicenow/sdk globally for this user.
    4. Adds the Node/SDK folders to the *user* PATH.
    5. Runs "now-sdk auth --add <instance> --type oauth" (browser sign-in + code paste).
    6. Verifies the stored credential by calling the instance REST API.

    Credentials are stored by the SDK in Windows Credential Manager for this user.
    Log file: %LOCALAPPDATA%\ServiceNowSdkSetup\setup.log

.PARAMETER InstanceUrl
    Instance URL or name, e.g. https://acme.service-now.com, acme.service-now.com, or dev12345.

.PARAMETER Alias
    Name for the saved connection. Defaults to the instance name.

.PARAMETER NoGui
    Use console prompts instead of dialog windows.

.PARAMETER SdkVersion
    @servicenow/sdk version to install.

.PARAMETER Force
    Sign in again even if a connection with this alias already exists.

.PARAMETER NoDefault
    Don't make this connection the SDK's default.

.PARAMETER NodeDir
    Where to put portable Node.js if needed. Default: %LOCALAPPDATA%\Programs\nodejs
#>
[CmdletBinding()]
param(
    [string]$InstanceUrl,
    [string]$Alias,
    [switch]$NoGui,
    [string]$SdkVersion = '4.12.2',
    [switch]$Force,
    [switch]$NoDefault,
    [string]$NodeDir = (Join-Path $env:LOCALAPPDATA 'Programs\nodejs')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:MinNodeVersion = [version]'20.18.0'
$script:PortableNodeDir = $NodeDir.TrimEnd('\')
$script:LogDir = Join-Path $env:LOCALAPPDATA 'ServiceNowSdkSetup'
$script:LogFile = Join-Path $script:LogDir 'setup.log'
$script:UserEnvKey = 'Environment'   # HKCU subkey holding the user PATH (overridable for tests)
$script:FullLanguage = $ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'
$script:UseGui = $false
$script:ProgressForm = $null
$script:ProgressBox = $null
$script:ProgressStatus = $null
$script:OAuthEndpointMissing = $false
$script:ExitCode = 0

$script:AdminGuidance = @"
Ask your ServiceNow administrator to check that the instance allows SDK sign-in:

  - The "ServiceNow IDE Runtime Services" plugin (com.glide.ide) is active.
  - System OAuth > Application Registry has an ACTIVE record named "ServiceNow SDK"
    (client ID 543e5655f77746a28228c6009a599dfb, redirect URL /sdk-oauth.do).
    If it is missing, an admin can import the file included with this tool:
    admin\oauth_entity_3b3ca1689f4c52103c50e2318a0a1c7f.xml
  - Your account can sign in to the instance (not blocked by IP, MFA or SSO rules).
"@

# ---------------------------------------------------------------------------
# Logging and UI
# ---------------------------------------------------------------------------

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Step', 'Warn', 'Error', 'Detail')][string]$Level = 'Info'
    )
    $stamp = (Get-Date).ToString('HH:mm:ss')
    try { Add-Content -LiteralPath $script:LogFile -Value "[$stamp] [$Level] $Message" -Encoding UTF8 } catch { }

    $color = switch ($Level) { 'Step' { 'Cyan' } 'Warn' { 'Yellow' } 'Error' { 'Red' } 'Detail' { 'DarkGray' } default { 'Gray' } }
    $prefix = switch ($Level) { 'Step' { '==> ' } 'Warn' { 'WARNING: ' } 'Error' { 'ERROR: ' } default { '    ' } }
    Write-Host "$prefix$Message" -ForegroundColor $color

    if ($script:ProgressBox) {
        $script:ProgressBox.AppendText("$prefix$Message`r`n")
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-Status {
    param([string]$Text)
    Write-Log $Text Step
    if ($script:ProgressStatus) {
        $script:ProgressStatus.Text = $Text
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Initialize-Gui {
    if (-not $script:FullLanguage) {
        Write-Log "PowerShell is running in $($ExecutionContext.SessionState.LanguageMode) mode (an application control policy is active). Using console mode instead of dialog windows." Warn
        return $false
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
        return $true
    }
    catch {
        Write-Log "Could not load Windows Forms ($($_.Exception.Message)). Using console mode." Warn
        return $false
    }
}

function Show-Message {
    param(
        [string]$Text,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Icon = 'Info',
        [switch]$YesNo,
        [string]$Prompt = 'Continue? [y/N]'
    )
    if ($script:UseGui) {
        $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
        try {
            $buttons = if ($YesNo) { [System.Windows.Forms.MessageBoxButtons]::YesNo } else { [System.Windows.Forms.MessageBoxButtons]::OK }
            $mbIcon = switch ($Icon) {
                'Warning' { [System.Windows.Forms.MessageBoxIcon]::Warning }
                'Error' { [System.Windows.Forms.MessageBoxIcon]::Error }
                default { [System.Windows.Forms.MessageBoxIcon]::Information }
            }
            $result = [System.Windows.Forms.MessageBox]::Show($owner, $Text, 'ServiceNow SDK Setup', $buttons, $mbIcon)
            if ($YesNo) { return ($result -eq [System.Windows.Forms.DialogResult]::Yes) }
            return
        }
        finally { $owner.Dispose() }
    }

    Write-Host ''
    Write-Host $Text
    Write-Host ''
    if ($YesNo) { return ((Read-Host $Prompt) -match '^\s*y') }
}

function Show-InputForm {
    param([string]$DefaultUrl, [string]$DefaultAlias, [bool]$DefaultMakeDefault)

    $state = @{ Url = $null; Alias = $null; MakeDefault = $DefaultMakeDefault; AliasTouched = [bool]$DefaultAlias }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'ServiceNow SDK Setup'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.ClientSize = New-Object System.Drawing.Size(480, 270)

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'This installs the ServiceNow SDK for your Windows account only (no admin rights needed) and connects it to your instance with OAuth. You will sign in through your browser.'
    $intro.Location = New-Object System.Drawing.Point(16, 14)
    $intro.Size = New-Object System.Drawing.Size(448, 48)

    $lblUrl = New-Object System.Windows.Forms.Label
    $lblUrl.Text = 'Instance URL:'
    $lblUrl.Location = New-Object System.Drawing.Point(16, 74)
    $lblUrl.AutoSize = $true

    $txtUrl = New-Object System.Windows.Forms.TextBox
    $txtUrl.Location = New-Object System.Drawing.Point(16, 94)
    $txtUrl.Size = New-Object System.Drawing.Size(448, 23)
    $txtUrl.Text = $DefaultUrl

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'e.g. https://acme.service-now.com  or just  dev12345'
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $hint.Location = New-Object System.Drawing.Point(16, 120)
    $hint.AutoSize = $true

    $lblAlias = New-Object System.Windows.Forms.Label
    $lblAlias.Text = 'Connection name (alias):'
    $lblAlias.Location = New-Object System.Drawing.Point(16, 148)
    $lblAlias.AutoSize = $true

    $txtAlias = New-Object System.Windows.Forms.TextBox
    $txtAlias.Location = New-Object System.Drawing.Point(16, 168)
    $txtAlias.Size = New-Object System.Drawing.Size(220, 23)
    $txtAlias.Text = $DefaultAlias

    $chkDefault = New-Object System.Windows.Forms.CheckBox
    $chkDefault.Text = 'Make this the default connection'
    $chkDefault.Location = New-Object System.Drawing.Point(16, 200)
    $chkDefault.AutoSize = $true
    $chkDefault.Checked = $DefaultMakeDefault

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Install and connect'
    $btnOk.Location = New-Object System.Drawing.Point(234, 230)
    $btnOk.Size = New-Object System.Drawing.Size(140, 28)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(384, 230)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 28)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    # Keep the alias in step with the URL until the user types their own.
    $txtAlias.Add_KeyPress({ $state.AliasTouched = $true })
    $txtUrl.Add_TextChanged({
            if (-not $state.AliasTouched) {
                $u = ConvertTo-InstanceUrl $txtUrl.Text
                $txtAlias.Text = if ($u) { Get-DefaultAlias $u } else { '' }
            }
        })

    $btnOk.Add_Click({
            $u = ConvertTo-InstanceUrl $txtUrl.Text
            if (-not $u) {
                [void][System.Windows.Forms.MessageBox]::Show($form, 'Enter a valid instance URL, for example https://acme.service-now.com', 'ServiceNow SDK Setup', 'OK', 'Warning')
                return
            }
            $a = $txtAlias.Text.Trim()
            if (-not (Test-AliasName $a)) {
                [void][System.Windows.Forms.MessageBox]::Show($form, 'The connection name can use letters, numbers, dot, dash and underscore (max 64 characters).', 'ServiceNow SDK Setup', 'OK', 'Warning')
                return
            }
            $state.Url = $u
            $state.Alias = $a
            $state.MakeDefault = $chkDefault.Checked
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        })

    $form.Controls.AddRange(@($intro, $lblUrl, $txtUrl, $hint, $lblAlias, $txtAlias, $chkDefault, $btnOk, $btnCancel))
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $result = $form.ShowDialog()
    $form.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return New-Object PSObject -Property @{ Url = $state.Url; Alias = $state.Alias; MakeDefault = $state.MakeDefault }
}

function Read-ConsoleInput {
    param([string]$DefaultUrl, [string]$DefaultAlias, [bool]$DefaultMakeDefault)

    $url = ConvertTo-InstanceUrl $DefaultUrl
    while (-not $url) {
        $v = Read-Host 'ServiceNow instance URL (e.g. https://acme.service-now.com or dev12345)'
        $url = ConvertTo-InstanceUrl $v
        if (-not $url) { Write-Host 'That does not look like a valid instance URL.' -ForegroundColor Yellow }
    }

    $name = $DefaultAlias
    while (-not (Test-AliasName $name)) {
        $suggested = Get-DefaultAlias $url
        $v = Read-Host "Connection name (alias) [$suggested]"
        $name = if ($v) { $v.Trim() } else { $suggested }
        if (-not (Test-AliasName $name)) { Write-Host 'Use letters, numbers, dot, dash and underscore only.' -ForegroundColor Yellow }
    }

    $makeDefault = $DefaultMakeDefault
    if ($DefaultMakeDefault) {
        $makeDefault = (Read-Host 'Make this the default connection? [Y/n]') -notmatch '^\s*n'
    }
    return New-Object PSObject -Property @{ Url = $url; Alias = $name; MakeDefault = $makeDefault }
}

function Show-ProgressForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'ServiceNow SDK Setup'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(680, 440)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = 'Vertical'
    $box.Dock = 'Fill'
    $box.BackColor = [System.Drawing.Color]::White
    $box.Font = New-Object System.Drawing.Font('Consolas', 9)

    $status = New-Object System.Windows.Forms.Label
    $status.Dock = 'Top'
    $status.Height = 34
    $status.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 0)
    $status.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $status.Text = 'Starting...'

    # Fill control first so the Top-docked label is laid out above it.
    $form.Controls.Add($box)
    $form.Controls.Add($status)
    $form.Add_FormClosed({
            $script:ProgressBox = $null
            $script:ProgressStatus = $null
            $script:ProgressForm = $null
        })

    $script:ProgressForm = $form
    $script:ProgressBox = $box
    $script:ProgressStatus = $status
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
}

function Close-ProgressForm {
    if ($script:ProgressForm) {
        $f = $script:ProgressForm
        $f.Close()
        $f.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

function ConvertTo-InstanceUrl {
    # Normalizes user input to https://host[:port]; returns $null if not usable.
    param([string]$Value)
    if (-not $Value) { return $null }
    $v = $Value.Trim()
    $label = '[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?'
    if ($v -notmatch "^(?:https?://)?(?<host>$label(?:\.$label)*)(?::(?<port>\d{1,5}))?(?:[/?#].*)?$") { return $null }
    $hostName = $Matches['host'].ToLowerInvariant()
    $port = $Matches['port']
    if (-not $hostName.Contains('.')) { $hostName = "$hostName.service-now.com" }
    $url = "https://$hostName"
    if ($port -and $port -ne '443') { $url += ":$port" }
    return $url
}

function Get-DefaultAlias {
    param([string]$Url)
    $hostName = $Url -replace '^https?://', '' -replace ':\d+$', ''
    return ($hostName -split '\.')[0]
}

function Test-AliasName {
    param([string]$Name)
    return [bool]($Name -and $Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
}

function ConvertTo-NodeVersion {
    param([string]$Text)
    if ($Text -match 'v?(\d+)\.(\d+)\.(\d+)') { return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" }
    return $null
}

function ConvertTo-QuotedArg {
    # Quotes one argument for a Windows command line (CommandLineToArgvW rules).
    param([string]$Arg)
    if ($Arg -and $Arg -notmatch '[\s"]') { return $Arg }
    $escaped = $Arg -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Expand-EnvString {
    # Expands %VAR% references without relying on .NET (works in Constrained Language Mode).
    param([string]$Text)
    $result = $Text
    foreach ($m in [regex]::Matches($Text, '%([^%;]+)%')) {
        $item = Get-Item -LiteralPath ("env:" + $m.Groups[1].Value) -ErrorAction SilentlyContinue
        if ($item) { $result = $result.Replace($m.Value, $item.Value) }
    }
    return $result
}

function Merge-PathEntries {
    # Returns the new PATH string with $Dirs prepended, or $null if nothing to add.
    param([string]$Existing, [string[]]$Dirs)
    $entries = @($Existing -split ';' | Where-Object { $_ })
    $known = @($entries | ForEach-Object { (Expand-EnvString $_).TrimEnd('\') })
    $toAdd = @()
    foreach ($d in $Dirs) {
        $clean = $d.TrimEnd('\')
        if ($known -notcontains $clean -and $toAdd -notcontains $clean) { $toAdd += $clean }
    }
    if ($toAdd.Count -eq 0) { return $null }
    return (@($toAdd) + $entries) -join ';'
}

# ---------------------------------------------------------------------------
# Process helpers
# ---------------------------------------------------------------------------

function Invoke-Captured {
    # Runs a native command and returns its exit code and combined output lines.
    param([string]$FilePath, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $FilePath @Arguments 2>&1 | ForEach-Object { ("$_" -replace "\x1b\[[0-9;]*m", '') }
        return New-Object PSObject -Property @{ ExitCode = $LASTEXITCODE; Output = @($out) }
    }
    finally { $ErrorActionPreference = $prev }
}

function Invoke-Streamed {
    # Runs a long native command, echoing output to the log (and GUI) as it arrives.
    param([string]$FilePath, [string[]]$Arguments)
    $acc = @{ Lines = @() }   # hashtable so the flush scriptblock can append (CLM-safe)

    if (-not $script:UseGui) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $FilePath @Arguments 2>&1 | ForEach-Object {
                $line = "$_" -replace "\x1b\[[0-9;]*m", ''
                $acc.Lines += $line
                Write-Log $line Detail
            }
            return New-Object PSObject -Property @{ ExitCode = $LASTEXITCODE; Output = $acc.Lines }
        }
        finally { $ErrorActionPreference = $prev }
    }

    # GUI: redirect to temp files and poll, so the window keeps repainting.
    $stamp = Get-Random
    $outFile = Join-Path $env:TEMP "snsdk-$stamp.out"
    $errFile = Join-Path $env:TEMP "snsdk-$stamp.err"
    $argLine = (@($Arguments) | ForEach-Object { ConvertTo-QuotedArg $_ }) -join ' '
    $proc = Start-Process -FilePath $FilePath -ArgumentList $argLine -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $proc.Handle   # PS 5.1: keeps ExitCode available after exit
    $seen = @{ $outFile = 0; $errFile = 0 }

    $flush = {
        param([bool]$final)
        foreach ($f in @($outFile, $errFile)) {
            $all = @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)
            # While running, hold back the last line: it may still be partially written.
            $upto = if ($final) { $all.Count } else { $all.Count - 1 }
            for ($i = $seen[$f]; $i -lt $upto; $i++) {
                $line = "$($all[$i])" -replace "\x1b\[[0-9;]*m", ''
                $acc.Lines += $line
                Write-Log $line Detail
            }
            if ($upto -gt $seen[$f]) { $seen[$f] = $upto }
        }
    }

    try {
        while (-not $proc.HasExited) {
            & $flush $false
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }
        $proc.WaitForExit()
        & $flush $true
        return New-Object PSObject -Property @{ ExitCode = $proc.ExitCode; Output = $acc.Lines }
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-DirWritable {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
        $probe = Join-Path $Path ".snsdk-write-test-$(Get-Random)"
        New-Item -ItemType File -Path $probe -Force | Out-Null
        Remove-Item -LiteralPath $probe -Force
        return $true
    }
    catch { return $false }
}

# ---------------------------------------------------------------------------
# Instance checks
# ---------------------------------------------------------------------------

function Test-InstanceReachable {
    param([string]$Url)
    $expectedHost = ($Url -replace '^https://', '' -replace ':\d+$', '')
    try {
        $r = Invoke-WebRequest -Uri "$Url/login.do" -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 5
    }
    catch {
        if ($_.Exception.Response) {
            Write-Log "The instance answered with HTTP $([int]$_.Exception.Response.StatusCode); continuing." Detail
            return
        }
        throw "Could not reach $Url.`n`n$($_.Exception.Message)`n`nCheck the URL, your internet/VPN connection, and try again."
    }

    $finalHost = "$($r.BaseResponse.ResponseUri.Host)"
    if ($finalHost -like '*developer.servicenow.com') {
        throw "Your developer instance appears to be hibernating.`n`nWake it up at https://developer.servicenow.com, wait until it is running, then run this setup again."
    }
    if ($r.Content -match 'hibernat') {
        Write-Log 'The instance page mentions hibernation. If this is a developer instance, make sure it is awake at https://developer.servicenow.com.' Warn
    }
    if ($finalHost -and $finalHost -ne $expectedHost) {
        Write-Log "Login page redirected to $finalHost (probably single sign-on). That's fine; you'll sign in through it in the browser." Detail
    }
    Write-Log "Instance $Url is reachable."
}

function Test-SdkOAuthEndpoint {
    # Soft check only: logs what the instance says about the SDK OAuth landing page.
    param([string]$Url)
    $code = $null
    try {
        $r = Invoke-WebRequest -Uri "$Url/sdk-oauth.do" -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 0
        $code = [int]$r.StatusCode
    }
    catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        else { Write-Log "Could not probe /sdk-oauth.do: $($_.Exception.Message)" Detail; return }
    }
    Write-Log "Probe of /sdk-oauth.do returned HTTP $code." Detail
    if ($code -eq 404) {
        $script:OAuthEndpointMissing = $true
        Write-Log 'The instance does not seem to have the SDK sign-in page (/sdk-oauth.do). Sign-in may fail; see the admin notes if it does.' Warn
    }
}

# ---------------------------------------------------------------------------
# Node.js
# ---------------------------------------------------------------------------

function Get-NodeInfo {
    # Runs a node.exe candidate. Returns $null if unusable, or an object with Error if it was blocked.
    param([string]$Candidate)
    try {
        $r = Invoke-Captured $Candidate @('-p', "process.version+'|'+process.execPath")
    }
    catch {
        return New-Object PSObject -Property @{ Error = $_.Exception.Message }
    }
    if ($r.ExitCode -ne 0) {
        return New-Object PSObject -Property @{ Error = "exit code $($r.ExitCode): $($r.Output -join ' ')" }
    }
    $line = $r.Output | Where-Object { $_ -match '^v\d+\.\d+\.\d+\|' } | Select-Object -First 1
    if (-not $line) { return $null }
    $parts = $line -split '\|', 2
    $exe = $parts[1].Trim()
    $npmCli = Join-Path (Split-Path -Parent $exe) 'node_modules\npm\bin\npm-cli.js'
    return New-Object PSObject -Property @{
        Error      = $null
        Version    = ConvertTo-NodeVersion $parts[0]
        Exe        = $exe
        NpmCli     = if (Test-Path -LiteralPath $npmCli) { $npmCli } else { $null }
        IsPortable = $exe -like "$($script:PortableNodeDir)\*"
    }
}

function Get-NodeArch {
    $a = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($a) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default { throw "This computer's processor architecture ($a) is not supported by current Node.js releases." }
    }
}

function Expand-Zip {
    param([string]$ZipPath, [string]$Destination)
    if ($script:FullLanguage) {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
            return
        }
        catch { Write-Log "Fast unzip failed ($($_.Exception.Message)); using Expand-Archive." Detail }
    }
    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
        return
    }
    catch { Write-Log "Expand-Archive failed ($($_.Exception.Message)); using tar.exe." Detail }
    # Windows 10 1803+ ships bsdtar, which reads zip files.
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $r = Invoke-Captured "$env:SystemRoot\System32\tar.exe" @('-xf', $ZipPath, '-C', $Destination)
    if ($r.ExitCode -ne 0) { throw "Could not unpack $ZipPath`: $($r.Output -join ' ')" }
}

function Get-Sha256 {
    param([string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    catch { Write-Log "Get-FileHash unavailable ($($_.Exception.Message)); using certutil." Detail }
    $r = Invoke-Captured 'certutil.exe' @('-hashfile', $Path, 'SHA256')
    $hash = $r.Output | Where-Object { ($_ -replace '\s', '') -match '^[0-9a-fA-F]{64}$' } | Select-Object -First 1
    if ($r.ExitCode -ne 0 -or -not $hash) { throw "Could not compute a checksum for $Path." }
    return ($hash -replace '\s', '')
}

function Get-AppControlMessage {
    param([string]$What, [string]$Detail)
    return @"
Windows blocked $What from running.
($Detail)

Your organization probably uses an application control policy (AppLocker or
WDAC) that only allows approved programs. Options:

  - Ask IT to allow Node.js from %LOCALAPPDATA%\Programs\nodejs, or
  - Install Node.js 20.18 or newer from Company Portal / Software Center,
    then run this setup again (it will use that Node.js automatically).
"@
}

function Install-PortableNode {
    $arch = Get-NodeArch
    Set-Status 'Downloading Node.js (portable, no admin needed)...'

    $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -UseBasicParsing -TimeoutSec 60
    $release = $index | Where-Object { $_.lts -and ($_.files -contains "win-$arch-zip") } | Select-Object -First 1
    if (-not $release) { throw "Could not find a Node.js LTS release for win-$arch." }
    $ver = $release.version
    $zipName = "node-$ver-win-$arch.zip"
    $base = "https://nodejs.org/dist/$ver"
    Write-Log "Latest Node.js LTS is $ver ($($release.lts))."

    $parent = Split-Path -Parent $script:PortableNodeDir
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    # Stage next to the destination so the final move stays on one volume.
    $staging = Join-Path $parent ".nodejs-setup-$(Get-Random)"
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        $zip = Join-Path $staging $zipName
        Write-Log "Downloading $base/$zipName"
        Invoke-WebRequest -Uri "$base/$zipName" -OutFile $zip -UseBasicParsing -TimeoutSec 600

        $sums = Invoke-RestMethod -Uri "$base/SHASUMS256.txt" -UseBasicParsing -TimeoutSec 60
        $expected = $null
        foreach ($line in ("$sums" -split "`n")) {
            $cols = $line.Trim() -split '\s+'
            if ($cols.Count -ge 2 -and $cols[1] -eq $zipName) { $expected = $cols[0] }
        }
        $actual = Get-Sha256 $zip
        if (-not $expected -or $actual -ne $expected) {
            throw "The Node.js download failed its checksum check (expected $expected, got $actual). Try again later."
        }
        Write-Log 'Checksum verified.'

        Set-Status 'Unpacking Node.js...'
        $extract = Join-Path $staging 'x'
        Expand-Zip -ZipPath $zip -Destination $extract
        $inner = Join-Path $extract "node-$ver-win-$arch"
        if (-not (Test-Path -LiteralPath (Join-Path $inner 'node.exe'))) { throw "Unexpected Node.js archive layout in $zipName." }

        if (Test-Path -LiteralPath $script:PortableNodeDir) {
            Write-Log "Replacing the older portable Node.js in $($script:PortableNodeDir)."
            $old = "$($script:PortableNodeDir).old-$(Get-Random)"
            Move-Item -LiteralPath $script:PortableNodeDir -Destination $old
            Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
        }
        Move-Item -LiteralPath $inner -Destination $script:PortableNodeDir
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    $exe = Join-Path $script:PortableNodeDir 'node.exe'
    $info = Get-NodeInfo $exe
    if (-not $info -or $info.Error) {
        $detail = if ($info) { $info.Error } else { 'no output' }
        throw (Get-AppControlMessage -What "Node.js ($exe)" -Detail $detail)
    }
    if (-not $info.NpmCli) { throw "npm is missing from the portable Node.js in $($script:PortableNodeDir)." }
    Write-Log "Installed Node.js $($info.Version) to $($script:PortableNodeDir)."
    return $info
}

function Resolve-Node {
    Set-Status 'Looking for Node.js...'
    $candidates = @()
    $onPath = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $candidates += $onPath.Source }
    $portableExe = Join-Path $script:PortableNodeDir 'node.exe'
    if ((Test-Path -LiteralPath $portableExe) -and ($candidates -notcontains $portableExe)) { $candidates += $portableExe }

    foreach ($c in $candidates) {
        $info = Get-NodeInfo $c
        if (-not $info) { Write-Log "Could not read the version of $c; skipping it." Detail; continue }
        if ($info.Error) { Write-Log "Could not run $c ($($info.Error)); skipping it." Warn; continue }
        if ($info.Version -lt $script:MinNodeVersion) {
            Write-Log "Found Node.js $($info.Version) at $($info.Exe), but the SDK needs $($script:MinNodeVersion) or newer." Warn
            continue
        }
        if (-not $info.NpmCli) { Write-Log "Found Node.js at $($info.Exe) but no npm next to it; skipping it." Warn; continue }
        Write-Log "Using Node.js $($info.Version) at $($info.Exe)."
        return $info
    }

    Write-Log 'No suitable Node.js found; a portable copy will be installed for your account.'
    return Install-PortableNode
}

# ---------------------------------------------------------------------------
# PATH (per user, HKCU)
# ---------------------------------------------------------------------------

function Get-UserPathRaw {
    # Unexpanded user PATH, so %VAR% entries survive the rewrite.
    if ($script:FullLanguage) {
        try {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:UserEnvKey)
            if (-not $key) { return '' }
            try { return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
            finally { $key.Close() }
        }
        catch { Write-Log "Registry API unavailable ($($_.Exception.Message)); using reg.exe." Detail }
    }
    $r = Invoke-Captured 'reg.exe' @('query', "HKCU\$($script:UserEnvKey)", '/v', 'Path')
    foreach ($line in $r.Output) {
        if ($line -match '^\s+Path\s+REG_(?:EXPAND_)?SZ\s*(.*)$') { return $Matches[1] }
    }
    return ''
}

function Set-UserPathRaw {
    param([string]$Value)
    if ($script:FullLanguage) {
        try {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:UserEnvKey)
            try { $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString); return }
            finally { $key.Close() }
        }
        catch { Write-Log "Registry API unavailable ($($_.Exception.Message)); using reg.exe." Detail }
    }
    # PowerShell 5.1 wraps arguments containing spaces in quotes; a trailing backslash
    # would then escape the closing quote, so double it.
    $arg = $Value
    if ($arg -match '\s' -and $arg.EndsWith('\')) { $arg += '\' }
    $r = Invoke-Captured 'reg.exe' @('add', "HKCU\$($script:UserEnvKey)", '/v', 'Path', '/t', 'REG_EXPAND_SZ', '/d', $arg, '/f')
    if ($r.ExitCode -ne 0) { throw "Could not update your PATH: $($r.Output -join ' ')" }
}

function Send-EnvironmentChange {
    # Setting a user variable through .NET broadcasts WM_SETTINGCHANGE for us.
    try {
        [Environment]::SetEnvironmentVariable('SNSDK_SETUP_REFRESH', '1', 'User')
        [Environment]::SetEnvironmentVariable('SNSDK_SETUP_REFRESH', $null, 'User')
        return $true
    }
    catch { return $false }
}

function Add-UserPathEntries {
    param([string[]]$Dirs)
    $raw = Get-UserPathRaw
    $new = Merge-PathEntries -Existing $raw -Dirs $Dirs
    if (-not $new) {
        Write-Log 'Your user PATH already includes the SDK folders.'
        return
    }
    Set-UserPathRaw $new
    Write-Log "Added to your user PATH: $($Dirs -join '; ')"
    if (-not (Send-EnvironmentChange)) {
        Write-Log 'Could not notify Windows of the PATH change. Sign out and back in if new terminals do not find now-sdk.' Warn
    }
}

function Get-MachineNodeDir {
    # Returns a machine-PATH folder containing node.exe (other than $Exclude), if any.
    param([string]$Exclude)
    $machinePath = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name Path -ErrorAction SilentlyContinue).Path
    foreach ($d in ("$machinePath" -split ';')) {
        if (-not $d) { continue }
        $dir = (Expand-EnvString $d).TrimEnd('\')
        if ($dir -ne $Exclude.TrimEnd('\') -and (Test-Path -LiteralPath (Join-Path $dir 'node.exe'))) { return $dir }
    }
    return $null
}

# ---------------------------------------------------------------------------
# ServiceNow SDK
# ---------------------------------------------------------------------------

function Install-Sdk {
    param($Node, [string]$Version)

    if ($Node.IsPortable) {
        # Put the SDK next to portable node.exe: npm's now-sdk.cmd shim prefers a sibling
        # node.exe, so it keeps working even if an older Node is first on the machine PATH.
        $prefix = Split-Path -Parent $Node.Exe
    }
    else {
        $r = Invoke-Captured $Node.Exe @($Node.NpmCli, 'prefix', '-g')
        $prefix = $r.Output | Where-Object { $_ -match '^[A-Za-z]:\\' } | Select-Object -Last 1
        if (-not $prefix -or -not (Test-DirWritable $prefix)) {
            if ($prefix) { Write-Log "npm's global folder ($prefix) is not writable without admin rights; using your profile instead." }
            $prefix = Join-Path $env:APPDATA 'npm'
        }
    }
    $prefix = "$prefix".TrimEnd('\')

    $sdkDir = Join-Path $prefix 'node_modules\@servicenow\sdk'
    $sdkJs = Join-Path $sdkDir 'bin\index.js'
    $pkgJson = Join-Path $sdkDir 'package.json'
    $result = New-Object PSObject -Property @{ Prefix = $prefix; SdkJs = $sdkJs; Version = $Version }

    if (Test-Path -LiteralPath $pkgJson) {
        $installed = (Get-Content -LiteralPath $pkgJson -Raw | ConvertFrom-Json).version
        if ($installed -eq $Version) {
            Write-Log "ServiceNow SDK $Version is already installed in $prefix."
            return $result
        }
        Write-Log "ServiceNow SDK $installed found; installing $Version."
    }

    Set-Status "Installing ServiceNow SDK $Version (this can take a few minutes)..."
    $npmArgs = @($Node.NpmCli, 'install', '--global', '--prefix', $prefix,
        "@servicenow/sdk@$Version", '--no-fund', '--no-audit', '--loglevel', 'warn')
    # Newer npm gates dependency install scripts; pre-approve the SDK dependencies whose
    # scripts fetch native binaries. Only pass it to npm versions that know the setting.
    $npmDefs = Join-Path (Split-Path -Parent (Split-Path -Parent $Node.NpmCli)) 'node_modules\@npmcli\config\lib\definitions\definitions.js'
    if ((Test-Path -LiteralPath $npmDefs) -and (Select-String -LiteralPath $npmDefs -Pattern "'allow-scripts'" -SimpleMatch -Quiet)) {
        $npmArgs += '--allow-scripts=@swc/core,libxmljs2,@parcel/watcher'
    }
    $r = Invoke-Streamed $Node.Exe $npmArgs
    if ($r.ExitCode -ne 0) {
        $text = $r.Output -join "`n"
        $hint = ''
        if ($text -match 'ENOTFOUND|ETIMEDOUT|ECONNREFUSED|ECONNRESET|EAI_AGAIN|proxy|SELF_SIGNED|UNABLE_TO_GET_ISSUER|UNABLE_TO_VERIFY') {
            $hint = "`n`nThis looks like a network problem reaching the npm registry (registry.npmjs.org). Check your connection/VPN and try again."
        }
        elseif ($text -match 'EPERM|EACCES|blocked|group policy') {
            $hint = "`n`nWindows denied access to a file. If your organization uses AppLocker/WDAC, it may be blocking Node.js add-ons; ask IT for help."
        }
        throw "Installing the ServiceNow SDK failed (npm exit code $($r.ExitCode)).$hint"
    }
    if (-not (Test-Path -LiteralPath $sdkJs)) { throw "npm finished but the SDK was not found at $sdkJs." }
    Write-Log "Installed ServiceNow SDK $Version into $prefix."
    return $result
}

function Invoke-Sdk {
    param([string[]]$Arguments)
    return Invoke-Captured $script:NodeExe (@($script:SdkJs) + $Arguments)
}

function Test-SdkAlias {
    param([string]$Name)
    $r = Invoke-Sdk @('auth', '--list')
    if ($r.ExitCode -ne 0) {
        $text = $r.Output -join ' '
        throw "The SDK could not read saved credentials: $text`n`nIf your organization uses AppLocker/WDAC, it may be blocking the SDK's credential-store add-on (@napi-rs/keyring)."
    }
    $pattern = '^\s*\*?\[' + [regex]::Escape($Name) + '\]\s*$'
    return [bool]($r.Output | Where-Object { $_ -match $pattern })
}

function Test-CredentialStoreSpace {
    # The SDK keeps all connections as one JSON blob in Windows Credential Manager. The
    # per-user store has a shared size quota; when it is full, saving fails with
    # "Platform secure storage failure: Windows error code 8" AFTER the user has signed in.
    # Probe with the SDK's own keyring module so we fail early with a useful message.
    $sdkDir = Split-Path -Parent (Split-Path -Parent $script:SdkJs)
    $probeJs = Join-Path $env:TEMP "snsdk-credprobe-$(Get-Random).js"
    @'
const sdkDir = process.argv[2];
const cli = require.resolve('@servicenow/sdk-cli', { paths: [sdkDir] });
const { Entry } = require(require.resolve('@napi-rs/keyring', { paths: [cli] }));
const e = new Entry('ServiceNowSdkSetupProbe', 'probe');
try {
  // ~2 KB as UTF-16: room for a few OAuth connections.
  e.setPassword('x'.repeat(1000));
  console.log('PROBE_OK');
} catch (err) {
  console.log('PROBE_FAIL ' + String(err.message).split('\n')[0]);
} finally {
  try { e.deletePassword(); } catch (_) {}
}
'@ | Set-Content -LiteralPath $probeJs -Encoding ASCII
    try { $r = Invoke-Captured $script:NodeExe @($probeJs, $sdkDir) }
    finally { Remove-Item -LiteralPath $probeJs -Force -ErrorAction SilentlyContinue }

    $result = $r.Output | Where-Object { $_ -match '^PROBE_' } | Select-Object -Last 1
    if ($result -eq 'PROBE_OK') {
        Write-Log 'Windows Credential Manager has room for the SDK credentials.'
        return
    }
    if (-not $result) {
        Write-Log "Could not check Credential Manager space ($($r.Output -join ' ')); continuing." Warn
        return
    }

    $detail = $result -replace '^PROBE_FAIL\s*', ''
    Write-Log "Credential Manager probe failed: $detail" Detail
    $targets = @(Invoke-Captured 'cmdkey.exe' @('/list')).Output | Where-Object { $_ -match 'Target:' }
    $total = @($targets).Count
    $xbox = @($targets | Where-Object { $_ -match 'target=XblGrts\|' }).Count
    Write-Log "Credential Manager holds $total entries ($xbox Xbox Live 'XblGrts')." Detail

    $xboxNote = ''
    if ($xbox -gt 0) {
        $xboxNote = @"

$xbox of them are Xbox Live "XblGrts" tokens. The Xbox app adds a new one at every
sign-in and they build up (a known Windows issue); Windows recreates them as needed.
To delete them (no admin needed), open PowerShell and run:

  cmdkey /list | Select-String 'target=(XblGrts\|\S+)' | ForEach-Object { cmdkey "/delete:`$(`$_.Matches[0].Groups[1].Value)" | Out-Null }
"@
    }
    throw @"
Windows Credential Manager is full, so the SDK would not be able to save your sign-in.
($detail)

Your credential store has $total saved entries.$xboxNote

You can also remove entries you no longer need in Control Panel > Credential Manager >
Windows Credentials. Then run this setup again.
"@
}

function Invoke-OAuthLogin {
    param([string]$Url, [string]$Name)

    $steps = @"
Next, sign in to ServiceNow:

  1. A browser window opens at $Url. Sign in as you normally do.
  2. If asked, allow access for "ServiceNow SDK".
  3. The page then shows a code. Copy it.
  4. Paste the code into the console window titled "ServiceNow SDK sign-in"
     and press Enter.

If the browser does not open, the console window shows a link to copy.
"@
    Set-Status 'Waiting for you to sign in...'

    if ($script:UseGui) {
        Show-Message $steps
        if ($script:ProgressForm) { $script:ProgressForm.Hide() }
        # A fresh console window gets focus and gives the SDK the real terminal it needs
        # for the code prompt. On failure it pauses so the error can be read.
        $cmdLine = '/d /s /c "title ServiceNow SDK sign-in & "' + $script:NodeExe + '" "' + $script:SdkJs +
        '" auth --add ' + $Url + ' --type oauth --alias ' + $Name +
        ' || (echo. & echo Sign-in did not complete. & pause)"'
        Start-Process -FilePath $env:ComSpec -ArgumentList $cmdLine -Wait
        if ($script:ProgressForm) { $script:ProgressForm.Show(); [System.Windows.Forms.Application]::DoEvents() }
    }
    else {
        Write-Host ''
        Write-Host $steps
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & $script:NodeExe $script:SdkJs auth --add $Url --type oauth --alias $Name }
        finally { $ErrorActionPreference = $prev }
    }
}

function Test-SdkConnection {
    param([string]$Url, [string]$Name)
    $r = Invoke-Sdk @('auth', '--print', $Name, '--format', 'bearer')
    if ($r.ExitCode -ne 0) {
        return New-Object PSObject -Property @{ Ok = $false; Reason = ($r.Output | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1) }
    }
    # The token is the only stdout line; SDK log lines are prefixed "[now-sdk]".
    $token = $r.Output | Where-Object { $_ -and $_ -notmatch '^\[now-sdk\]' -and $_ -notmatch '\s' } | Select-Object -Last 1
    if (-not $token) { return New-Object PSObject -Property @{ Ok = $false; Reason = 'The SDK did not return a token.' } }

    $code = $null
    try {
        $resp = Invoke-WebRequest -Uri "$Url/api/now/table/sys_user?sysparm_limit=1&sysparm_fields=sys_id" `
            -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json' } -UseBasicParsing -TimeoutSec 30
        $code = [int]$resp.StatusCode
    }
    catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        else { return New-Object PSObject -Property @{ Ok = $false; Reason = $_.Exception.Message } }
    }
    finally { $token = $null }

    # 403 means the token was accepted but this user can't read sys_user - still a valid login.
    if ($code -eq 200 -or $code -eq 403) { return New-Object PSObject -Property @{ Ok = $true; Reason = "HTTP $code" } }
    return New-Object PSObject -Property @{ Ok = $false; Reason = "The instance rejected the token (HTTP $code)." }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Invoke-Main {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    if (Test-Path -LiteralPath $script:LogFile) {
        Move-Item -LiteralPath $script:LogFile -Destination (Join-Path $script:LogDir 'setup.previous.log') -Force
    }
    Write-Log "Setup started: PowerShell $($PSVersionTable.PSVersion), $($ExecutionContext.SessionState.LanguageMode) mode, user $env:USERNAME" Detail

    $env:NO_COLOR = '1'
    $env:FORCE_COLOR = '0'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    try { Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File | Unblock-File } catch { }

    $script:UseGui = (-not $NoGui) -and (Initialize-Gui)

    # --- Inputs ---
    if ($InstanceUrl -and -not (ConvertTo-InstanceUrl $InstanceUrl)) { throw "'$InstanceUrl' is not a valid instance URL." }
    if ($Alias -and -not (Test-AliasName $Alias)) { throw "'$Alias' is not a valid alias (letters, numbers, dot, dash, underscore)." }
    $makeDefault = -not $NoDefault

    if ($InstanceUrl -and $Alias) {
        $in = New-Object PSObject -Property @{ Url = (ConvertTo-InstanceUrl $InstanceUrl); Alias = $Alias; MakeDefault = $makeDefault }
    }
    elseif ($script:UseGui) {
        $defaultUrl = if ($InstanceUrl) { $InstanceUrl } else { '' }
        $defaultAlias = if ($Alias) { $Alias } elseif ($InstanceUrl) { Get-DefaultAlias (ConvertTo-InstanceUrl $InstanceUrl) } else { '' }
        $in = Show-InputForm -DefaultUrl $defaultUrl -DefaultAlias $defaultAlias -DefaultMakeDefault $makeDefault
        if (-not $in) { Write-Log 'Setup cancelled.'; return }
    }
    else {
        $in = Read-ConsoleInput -DefaultUrl $InstanceUrl -DefaultAlias $Alias -DefaultMakeDefault $makeDefault
    }
    $url = $in.Url
    $name = $in.Alias
    Write-Log "Instance: $url   Alias: $name   Default: $($in.MakeDefault)"

    if ($script:UseGui) { Show-ProgressForm }

    # --- 1. Instance ---
    Set-Status "Step 1 of 5: Checking $url..."
    Test-InstanceReachable $url
    Test-SdkOAuthEndpoint $url

    # --- 2. Node.js ---
    Set-Status 'Step 2 of 5: Node.js'
    $node = Resolve-Node
    $script:NodeExe = $node.Exe

    # --- 3. SDK ---
    Set-Status 'Step 3 of 5: ServiceNow SDK'
    $sdk = Install-Sdk -Node $node -Version $SdkVersion
    $script:SdkJs = $sdk.SdkJs

    # --- 4. PATH ---
    Set-Status 'Step 4 of 5: Updating your PATH'
    $nodeDir = Split-Path -Parent $node.Exe
    $pathDirs = @($sdk.Prefix)
    if ($node.IsPortable -and $pathDirs -notcontains $nodeDir) { $pathDirs = @($nodeDir) + $pathDirs }
    Add-UserPathEntries -Dirs $pathDirs
    $env:Path = (@($pathDirs) + @($env:Path)) -join ';'

    $shadow = $null
    if ($node.IsPortable) {
        $shadow = Get-MachineNodeDir -Exclude $nodeDir
        if ($shadow) {
            Write-Log "An older Node.js in $shadow comes first on the system PATH, so typing 'node' in a new terminal will still run that one. 'now-sdk' is set up to use the new Node.js regardless." Warn
        }
    }

    # --- 5. Sign in ---
    Set-Status 'Step 5 of 5: Connecting to your instance'
    $exists = Test-SdkAlias $name
    $doLogin = $true
    if ($exists -and -not $Force) {
        $doLogin = Show-Message "A connection named '$name' is already saved.`n`nSign in again and replace it?" -YesNo -Prompt "Sign in again and replace '$name'? [y/N]"
    }
    if ($doLogin) {
        Test-CredentialStoreSpace
        if ($exists) {
            Write-Log "Removing the existing '$name' connection."
            $r = Invoke-Sdk @('auth', '--delete', $name)
            if ($r.ExitCode -ne 0) { throw "Could not remove the existing '$name' connection: $($r.Output -join ' ')" }
        }
        Invoke-OAuthLogin -Url $url -Name $name
        if (-not (Test-SdkAlias $name)) {
            $extra = if ($script:OAuthEndpointMissing) { "`n`nThe instance did not recognise the SDK sign-in page (/sdk-oauth.do)." } else { '' }
            throw "Sign-in did not complete, so no connection was saved.$extra`n`nIf you finished signing in and still see this:`n`n$($script:AdminGuidance)"
        }
        Write-Log "Saved connection '$name'."
    }
    else {
        Write-Log "Keeping the existing '$name' connection."
    }

    if ($in.MakeDefault) {
        $r = Invoke-Sdk @('auth', '--use', $name)
        if ($r.ExitCode -eq 0) { Write-Log "'$name' is now the default connection." }
        else { Write-Log "Could not set '$name' as default: $($r.Output -join ' ')" Warn }
    }

    Set-Status 'Verifying the connection...'
    $check = Test-SdkConnection -Url $url -Name $name
    if (-not $check.Ok) {
        throw "The connection was saved but could not be verified: $($check.Reason)`n`nTry running this setup again and choose to sign in again. If it keeps failing:`n`n$($script:AdminGuidance)"
    }
    Write-Log "Verified: the instance accepted the SDK's token ($($check.Reason))."

    # --- Summary ---
    $defaultNote = if ($in.MakeDefault) { ' (default)' } else { '' }
    $shadowNote = if ($shadow) { "`nNote: 'node' in new terminals may still be the older copy in $shadow.`n" } else { '' }
    $summary = @"
The ServiceNow SDK is ready.

  Instance:  $url
  Alias:     $name$defaultNote
  SDK:       now-sdk $($sdk.Version)
  Node.js:   $($node.Version)  ($($node.Exe))
  Log:       $($script:LogFile)
$shadowNote
Open a NEW terminal window (so it picks up your updated PATH), then try:

  now-sdk --help
  now-sdk auth --list
  now-sdk init          (start a new app project)
"@
    Set-Status 'Done.'
    Write-Log $summary
    Show-Message $summary
}

# Skip execution when dot-sourced (used by the test harness).
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-Main
    }
    catch {
        $script:ExitCode = 1
        $msg = $_.Exception.Message
        Write-Log $msg Error
        try { Add-Content -LiteralPath $script:LogFile -Value $_.ScriptStackTrace -Encoding UTF8 } catch { }
        if ($script:UseGui) {
            try { Show-Message "Setup did not finish.`n`n$msg`n`nLog file: $($script:LogFile)" -Icon Error } catch { }
        }
    }
    finally {
        Close-ProgressForm
    }
    exit $script:ExitCode
}
