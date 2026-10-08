<#
.SYNOPSIS
    Runs each MailStore Home archiving profile on this VM, showing a progress
    window, then closes the app.

.DESCRIPTION
    One copy per VM. Edit the CONFIGURE block, then:

        .\Invoke-MailStoreArchive.ps1              # run once, by hand, to test
        .\Invoke-MailStoreArchive.ps1 -NoUi        # run with no status window
        .\Invoke-MailStoreArchive.ps1 -Install     # register the daily task
        .\Invoke-MailStoreArchive.ps1 -Uninstall   # remove it

    Mirrors exactly what MailStore's own desktop shortcuts do:

        Target : D:\Mailstore\Application\MailStoreHome.exe
        Args   : /portable /c archive --id="2"
        WorkDir: D:\Mailstore\Application

    All three details matter - wrong exe, /c before /portable, or the wrong
    working directory and MailStore just opens on the home screen and sits there.

    Profiles run one at a time; combined --id="1,2,3" has been reported to skip
    profiles. MailStore does not exit on its own when archiving finishes, so
    this script watches CPU and closes each run once it goes idle.

    Needs an active desktop session. Locked or RDP-disconnected is fine,
    logged out is not.

.PARAMETER NoUi
    Suppress the status window (useful if you ever want it fully silent).
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$NoUi,
    [string]$RunAt = '07:30'
)

# ----------------------------------------------------------------------------
# CONFIGURE THIS BLOCK (per VM)
# ----------------------------------------------------------------------------
$Exe     = 'D:\Mailstore\Application\MailStoreHome.exe'
$WorkDir = 'D:\Mailstore\Application'
$PreArgs = '/portable'          # '' for a normally installed copy
$DataDir = 'D:\Mailstore\Data'  # for stale .lock cleanup; '' to skip

# Profile IDs, each run separately. Verify with:
#   select profile -> Create Shortcut on Desktop -> shortcut Properties -> Target
$Profiles = @(
    @{ Id = '1';  Label = 'My Mailbox' }
    # @{ Id = '2';  Label = 'Work Mailbox' }
)

$TimeoutMinutes  = 30      # hard stop per profile
$IdleSeconds     = 90      # near-zero CPU for this long = finished
$MinRunSeconds   = 45      # startup grace
$ShowMailStore   = $false  # $true to see MailStore's own window too (steals focus)
$KeepWindowSecs  = 20      # linger on the summary before auto-closing
$WindowTopMost   = $false  # $true to keep the status window above other apps
$LogDir          = Join-Path $env:LOCALAPPDATA 'MailStoreAuto\logs'
$KeepLogDays     = 60
$TaskName        = 'MailStore Daily Archive'
# ----------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ('mailstore-{0}-{1:yyyy-MM-dd}.log' -f $env:COMPUTERNAME, (Get-Date))

# --- install / uninstall ----------------------------------------------------

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed '$TaskName' from $env:COMPUTERNAME."
    return
}

if ($Install) {
    $self = $MyInvocation.MyCommand.Path
    if ($self -like "$env:TEMP*" -or $self -like '*\Downloads\*') {
        Write-Warning "Script is at $self - move it somewhere permanent before installing."
    }

    # Console stays hidden; the status window is what you see.
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$self`""

    $trigger  = New-ScheduledTaskTrigger -Daily -At $RunAt

    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew

    # Interactive: both MailStore and the status window need the desktop session.
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force `
        -Description 'Runs each MailStore Home profile with a progress window, then closes the app.' | Out-Null

    Write-Host "Registered '$TaskName' on $env:COMPUTERNAME for $RunAt daily, as $env:USERDOMAIN\$env:USERNAME."
    Write-Host "Test with:  Start-ScheduledTask -TaskName '$TaskName'"
    return
}

# --- status window ----------------------------------------------------------

$script:Ui = $null

function Initialize-Ui {
    if ($NoUi) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
    } catch {
        Write-Warning "Could not load WinForms - continuing without the status window."
        return
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = "MailStore Archive - $env:COMPUTERNAME"
    $form.Size            = New-Object System.Drawing.Size(620, 420)
    $form.StartPosition   = 'CenterScreen'
    $form.TopMost         = $WindowTopMost
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox     = $false
    $form.BackColor       = [System.Drawing.Color]::FromArgb(250, 250, 250)

    $lblStep = New-Object System.Windows.Forms.Label
    $lblStep.Location  = New-Object System.Drawing.Point(16, 14)
    $lblStep.Size      = New-Object System.Drawing.Size(570, 26)
    $lblStep.Font      = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $lblStep.Text      = 'Starting...'
    $form.Controls.Add($lblStep)

    $lblDetail = New-Object System.Windows.Forms.Label
    $lblDetail.Location = New-Object System.Drawing.Point(16, 42)
    $lblDetail.Size     = New-Object System.Drawing.Size(570, 20)
    $lblDetail.Font     = New-Object System.Drawing.Font('Segoe UI', 9)
    $lblDetail.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $form.Controls.Add($lblDetail)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(16, 70)
    $bar.Size     = New-Object System.Drawing.Size(570, 20)
    $bar.Minimum  = 0
    $bar.Maximum  = [Math]::Max(1, $Profiles.Count)
    $bar.Value    = 0
    $form.Controls.Add($bar)

    $log = New-Object System.Windows.Forms.TextBox
    $log.Location   = New-Object System.Drawing.Point(16, 102)
    $log.Size       = New-Object System.Drawing.Size(570, 250)
    $log.Multiline  = $true
    $log.ScrollBars = 'Vertical'
    $log.ReadOnly   = $true
    $log.BackColor  = [System.Drawing.Color]::White
    $log.Font       = New-Object System.Drawing.Font('Consolas', 9)
    $form.Controls.Add($log)

    # Closing the window must not abort archiving - just go headless.
    $form.Add_FormClosed({ $script:Ui = $null })

    $script:Ui = [PSCustomObject]@{
        Form = $form; Step = $lblStep; Detail = $lblDetail; Bar = $bar; Log = $log
    }
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-UiStep {
    param([string]$Step, [string]$Detail = '', [int]$Completed = -1)
    if (-not $script:Ui) { return }
    try {
        $script:Ui.Step.Text = $Step
        if ($Detail) { $script:Ui.Detail.Text = $Detail }
        if ($Completed -ge 0) { $script:Ui.Bar.Value = [Math]::Min($Completed, $script:Ui.Bar.Maximum) }
        [System.Windows.Forms.Application]::DoEvents()
    } catch { $script:Ui = $null }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0:HH:mm:ss}  [{1}]  {2}' -f (Get-Date), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd} {1}' -f (Get-Date), $line)
    if ($script:Ui) {
        try {
            $script:Ui.Log.AppendText($line + [Environment]::NewLine)
            [System.Windows.Forms.Application]::DoEvents()
        } catch { $script:Ui = $null }
    }
}

# Sleep that keeps the window responsive and the elapsed counter ticking.
function Wait-Ui {
    param([int]$Seconds, [string]$Step, [datetime]$Since)
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        if ($script:Ui -and $Step) {
            $mins = [int]((Get-Date) - $Since).TotalSeconds
            Set-UiStep -Step $Step -Detail ("Elapsed {0:mm\:ss} - waiting for MailStore to finish" -f ([TimeSpan]::FromSeconds($mins)))
        }
        Start-Sleep -Milliseconds 250
    }
}

# --- helpers ----------------------------------------------------------------

$ProcName = [IO.Path]::GetFileNameWithoutExtension($Exe)

function Stop-MailStore {
    Get-Process -Name $ProcName -ErrorAction SilentlyContinue | ForEach-Object {
        $null = $_.CloseMainWindow()
        Start-Sleep -Seconds 5
        $_.Refresh()
        if (-not $_.HasExited) { $_ | Stop-Process -Force }
    }
    Start-Sleep -Seconds 3
}

function Clear-StaleLocks {
    # Only safe with no MailStore process running. A force-killed MailStore
    # leaves .lock files that block the next run's database access.
    if (-not $DataDir -or -not (Test-Path -LiteralPath $DataDir)) { return }
    if (Get-Process -Name $ProcName -ErrorAction SilentlyContinue) { return }
    $locks = Get-ChildItem -Path $DataDir -Filter '*.lock' -Recurse -ErrorAction SilentlyContinue
    if ($locks) {
        Write-Log "Clearing $($locks.Count) stale .lock file(s)" 'WARN'
        $locks | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Profile {
    param([string]$Id, [string]$Label, [int]$Index, [int]$Total)

    $stepText = "Profile $Index of $Total - $Label"
    Set-UiStep -Step $stepText -Detail 'Closing any running MailStore...' -Completed ($Index - 1)

    Stop-MailStore
    Clear-StaleLocks

    $argString = ('{0} /c archive --id="{1}"' -f $PreArgs, $Id).TrimStart()
    Write-Log "[$Label] id=$Id starting"
    Set-UiStep -Step $stepText -Detail 'Starting MailStore...'

    $style = if ($ShowMailStore) { 'Normal' } else { 'Minimized' }
    $proc = Start-Process -FilePath $Exe -ArgumentList $argString `
        -WorkingDirectory $WorkDir -PassThru -WindowStyle $style

    $started   = Get-Date
    $timeout   = [TimeSpan]::FromMinutes($TimeoutMinutes)
    $lastCpu   = 0.0
    $idleSince = $null

    while ($true) {
        Wait-Ui -Seconds 10 -Step $stepText -Since $started

        if ($proc.HasExited) {
            Write-Log "[$Label] exited on its own after $([int]((Get-Date) - $started).TotalSeconds)s"
            return $true
        }

        $proc.Refresh()
        $cpu     = $proc.TotalProcessorTime.TotalSeconds
        $delta   = $cpu - $lastCpu
        $lastCpu = $cpu
        $elapsed = (Get-Date) - $started

        if ($elapsed -gt $timeout) {
            Write-Log "[$Label] timeout after $TimeoutMinutes min - forcing close, may be incomplete" 'ERROR'
            $proc | Stop-Process -Force
            return $false
        }

        if ($delta -lt 0.5 -and $elapsed.TotalSeconds -gt $MinRunSeconds) {
            if (-not $idleSince) { $idleSince = Get-Date }
            $idleFor = ((Get-Date) - $idleSince).TotalSeconds
            Set-UiStep -Step $stepText -Detail ("Archiving looks done - confirming ({0}/{1}s idle)" -f [int]$idleFor, $IdleSeconds)
            if ($idleFor -ge $IdleSeconds) {
                Write-Log "[$Label] finished in $([int]$elapsed.TotalSeconds)s, closing"
                Set-UiStep -Step $stepText -Detail 'Closing MailStore...'
                $null = $proc.CloseMainWindow()
                Start-Sleep -Seconds 8
                $proc.Refresh()
                if (-not $proc.HasExited) { $proc | Stop-Process -Force }
                return $true
            }
        } else {
            $idleSince = $null
        }
    }
}

# --- run --------------------------------------------------------------------

Initialize-Ui
Write-Log "===== run started on $env:COMPUTERNAME ====="

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Log "Executable not found at $Exe" 'ERROR'
    Set-UiStep -Step 'Failed' -Detail "Executable not found at $Exe"
    Wait-Ui -Seconds 30
    exit 1
}

$failed = 0
$i = 0
foreach ($p in $Profiles) {
    $i++
    try {
        if (-not (Invoke-Profile -Id $p.Id -Label $p.Label -Index $i -Total $Profiles.Count)) { $failed++ }
    } catch {
        Write-Log "[$($p.Label)] $($_.Exception.Message)" 'ERROR'
        $failed++
    }
    Set-UiStep -Completed $i
    Start-Sleep -Seconds 5
}

Stop-MailStore
Clear-StaleLocks

$ok = $Profiles.Count - $failed
Write-Log "===== run finished, $ok/$($Profiles.Count) profiles OK ====="

if ($failed -gt 0) {
    Set-UiStep -Step "Finished with $failed problem(s)" -Detail "$ok of $($Profiles.Count) profiles archived - see the log below" -Completed $Profiles.Count
    Wait-Ui -Seconds ([Math]::Max($KeepWindowSecs, 120))   # linger longer on failure
} else {
    Set-UiStep -Step 'All profiles archived' -Detail "$ok of $($Profiles.Count) complete - closing shortly" -Completed $Profiles.Count
    Wait-Ui -Seconds $KeepWindowSecs
}

if ($script:Ui) { try { $script:Ui.Form.Close() } catch { } }

Get-ChildItem -Path $LogDir -Filter 'mailstore-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepLogDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

exit ([int]($failed -gt 0))