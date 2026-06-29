#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [string]$WhimboxRepo = "nikkigallery/Whimbox",
    [string]$ScriptsRepo = "nikkigallery/WhimboxScripts",
    [int]$RpcPort = 8350,
    [switch]$SkipAppLaunch,
    [switch]$SkipScriptRefresh,
    [switch]$NoPromptInstallDir
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[qixiang-update] $Message"
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Warning "[qixiang-update] $Message"
}

function Get-KnownInstallCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($env:QIXIANG_INSTALL_DIR)) {
        $candidates.Add($env:QIXIANG_INSTALL_DIR)
    }

    $candidates.Add("D:\APP\whimbox_app")
    $candidates.Add("D:\whimbox_app")
    $candidates.Add("C:\APP\whimbox_app")

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA "Programs\whimbox_app"))
    }

    $result = @()
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate).Trim('"')
        if ($result -notcontains $expanded) {
            $result += $expanded
        }
    }
    return $result
}

function Get-ExistingInstallDir {
    foreach ($candidate in Get-KnownInstallCandidates) {
        $exe = Join-Path $candidate "whimbox_app.exe"
        if (Test-Path -LiteralPath $exe) {
            return $candidate
        }
    }
    return $null
}

function Get-RecommendedInstallDir {
    if (Test-Path -LiteralPath "D:\") {
        return "D:\APP\whimbox_app"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return (Join-Path $env:LOCALAPPDATA "Programs\whimbox_app")
    }
    return "C:\APP\whimbox_app"
}

function Resolve-InstallDirectory {
    param(
        [AllowNull()][string]$RequestedDir,
        [switch]$NoPrompt
    )

    $chosen = $RequestedDir
    $source = "command line"

    if ([string]::IsNullOrWhiteSpace($chosen) -and -not [string]::IsNullOrWhiteSpace($env:QIXIANG_INSTALL_DIR)) {
        $chosen = $env:QIXIANG_INSTALL_DIR
        $source = "QIXIANG_INSTALL_DIR"
    }

    if ([string]::IsNullOrWhiteSpace($chosen)) {
        $existing = Get-ExistingInstallDir
        if (-not [string]::IsNullOrWhiteSpace($existing)) {
            $chosen = $existing
            $source = "existing install"
        }
    }

    if ([string]::IsNullOrWhiteSpace($chosen)) {
        $chosen = Get-RecommendedInstallDir
        $source = "recommended default"

        if (-not $NoPrompt) {
            Write-Host ""
            Write-Host "Whimbox install directory is not fixed for every computer."
            Write-Host "Press Enter to use the default path, or type another full path."
            try {
                $answer = Read-Host "Install path [$chosen]"
            } catch {
                $answer = ""
            }
            if (-not [string]::IsNullOrWhiteSpace($answer)) {
                $chosen = $answer
                $source = "interactive input"
            }
        }
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($chosen).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($expanded)) {
        throw "Install directory cannot be empty."
    }

    $fullPath = [IO.Path]::GetFullPath($expanded).TrimEnd('\')
    Write-Step "Using install directory ($source): $fullPath"
    return $fullPath
}

[Net.ServicePointManager]::SecurityProtocol = `
    [Net.SecurityProtocolType]::Tls12 -bor `
    [Net.SecurityProtocolType]::Tls11 -bor `
    [Net.SecurityProtocolType]::Tls

$GitHubHeaders = @{
    "User-Agent" = "qixiang-update-script"
    "Accept" = "application/vnd.github+json"
}

$InstallDir = Resolve-InstallDirectory -RequestedDir $InstallDir -NoPrompt:$NoPromptInstallDir
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RunStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$TempRoot = Join-Path $ScriptRoot "_tmp_$RunStamp"
$DownloadDir = Join-Path $TempRoot "downloads"
$ExtractDir = Join-Path $TempRoot "extract"
$BackupRoot = Join-Path $ScriptRoot "_backup_$RunStamp"
$InstallBackupDir = Join-Path $BackupRoot "whimbox_app"
$TargetScriptsDir = Join-Path $InstallDir "scripts"
$ScriptsBackupDir = Join-Path $BackupRoot "scripts"
$BackendStatusFile = Join-Path $env:APPDATA "whimbox_app\backend-status.json"
$BackendStatusBackupFile = Join-Path $BackupRoot "backend-status.json"

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Remove-PathRobust {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lastError = $null
    for ($i = 0; $i -lt 3; $i++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            $lastError = $_
            Start-Sleep -Seconds 1
        }
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) {
        $args = "/c rmdir /s /q `"$Path`""
    } else {
        $args = "/c del /f /q `"$Path`""
    }
    $process = Start-Process -FilePath "cmd.exe" -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0 -or (Test-Path -LiteralPath $Path)) {
        throw "Failed to remove: $Path. Last error: $lastError"
    }
}

function Invoke-GitHubApi {
    param([Parameter(Mandatory = $true)][string]$Uri)
    Invoke-RestMethod -Headers $GitHubHeaders -Uri $Uri
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Ensure-Directory (Split-Path -Parent $Destination)
    if (Test-Path -LiteralPath $Destination) {
        Remove-PathRobust $Destination
    }
    Write-Step "Downloading $Uri"
    Invoke-WebRequest -Headers $GitHubHeaders -Uri $Uri -OutFile $Destination
    $item = Get-Item -LiteralPath $Destination -ErrorAction Stop
    if ($item.Length -le 0) {
        throw "Downloaded file is empty: $Destination"
    }
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Mirror
    )

    Ensure-Directory $Destination
    $mode = if ($Mirror) { "/MIR" } else { "/E" }
    & robocopy.exe $Source $Destination $mode /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    $code = $LASTEXITCODE
    if ($code -gt 7) {
        throw "Robocopy failed with exit code $code. Source: $Source Destination: $Destination"
    }
    $global:LASTEXITCODE = 0
}

function Stop-ProcessesUnderPath {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $rootFullPath = $null
    if (Test-Path -LiteralPath $RootPath) {
        $rootFullPath = [IO.Path]::GetFullPath($RootPath).TrimEnd("\")
    }
    $targets = @()
    foreach ($proc in Get-Process) {
        $procPath = $null
        try {
            $procPath = $proc.Path
        } catch {
            $procPath = $null
        }

        $isWhimboxProcess = $proc.ProcessName -match "^(whimbox_app|whimbox)$"
        $isUnderRoot = $rootFullPath -and $procPath -and $procPath.StartsWith($rootFullPath, [StringComparison]::OrdinalIgnoreCase)
        if ($isUnderRoot -or $isWhimboxProcess) {
            $targets += $proc
        }
    }

    if ($targets.Count -eq 0) {
        return
    }

    Write-Step "Stopping running Whimbox processes from $rootFullPath"
    foreach ($proc in $targets) {
        try {
            if ($proc.MainWindowHandle -ne 0) {
                [void]$proc.CloseMainWindow()
            }
        } catch {
        }
    }

    Start-Sleep -Seconds 3

    foreach ($proc in $targets) {
        try {
            $stillRunning = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
            if ($stillRunning) {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            }
        } catch {
        }
    }

    Start-Sleep -Seconds 2
    $remaining = @()
    foreach ($proc in $targets) {
        $stillRunning = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($stillRunning) {
            $remaining += $stillRunning
        }
    }

    if ($remaining.Count -gt 0) {
        $ids = ($remaining | ForEach-Object { "$($_.ProcessName)#$($_.Id)" }) -join ", "
        throw "Some Whimbox processes could not be closed automatically: $ids. Please close Whimbox/error popups manually, then rerun this script."
    }
}

function Get-AppExecutable {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $direct = Join-Path $RootPath "whimbox_app.exe"
    if (Test-Path -LiteralPath $direct) {
        return $direct
    }

    if (-not (Test-Path -LiteralPath $RootPath)) {
        return $null
    }

    $ignored = "(?i)(uninstall|unins|setup|elevate|crashpad|helper)"
    $candidates = Get-ChildItem -LiteralPath $RootPath -Recurse -Filter "*.exe" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch $ignored }

    $preferred = $candidates |
        Where-Object { $_.Name -match "(?i)(whimbox|launcher)" } |
        Sort-Object FullName |
        Select-Object -First 1

    if ($preferred) {
        return $preferred.FullName
    }

    $first = $candidates | Sort-Object FullName | Select-Object -First 1
    if ($first) {
        return $first.FullName
    }

    return $null
}

function Normalize-VersionString {
    param([AllowNull()][string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }

    $clean = $Version.Trim()
    if ($clean -match "^(\d+(?:\.\d+){0,3})") {
        $parts = @($Matches[1] -split "\.")
        while ($parts.Count -lt 3) {
            $parts += "0"
        }
        return ($parts[0..2] -join ".")
    }

    return $clean.ToLowerInvariant()
}

function Get-SetupVersionFromName {
    param([Parameter(Mandatory = $true)][string]$SetupName)

    if ($SetupName -notmatch "^whimbox_app-setup-(?<version>\d+(?:\.\d+){1,3})\.exe$") {
        throw "Cannot parse app setup version from: $SetupName"
    }

    return Normalize-VersionString $Matches.version
}

function Get-InstalledAppVersion {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $appExe = Get-AppExecutable $RootPath
    if (-not $appExe) {
        return $null
    }

    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($appExe)
    foreach ($value in @($versionInfo.ProductVersion, $versionInfo.FileVersion)) {
        $normalized = Normalize-VersionString $value
        if ($normalized) {
            return $normalized
        }
    }

    return $null
}

function Get-InstallerKind {
    param([Parameter(Mandatory = $true)][string]$InstallerPath)

    $stream = [IO.File]::OpenRead($InstallerPath)
    try {
        $maxBytes = [Math]::Min($stream.Length, 16MB)
        $buffer = New-Object byte[] ([int]$maxBytes)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $text = [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        if ($text -match "Nullsoft|NSIS") {
            return "nsis"
        }
        if ($text -match "Inno Setup") {
            return "inno"
        }
        return "unknown"
    } finally {
        $stream.Dispose()
    }
}

function Invoke-WhimboxInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$TargetDir
    )

    $kind = Get-InstallerKind $InstallerPath
    Write-Step "Installer type detected as: $kind"

    $nsisAttempt = @{
        Name = "NSIS silent install"
        Args = @("/S", "/D=$TargetDir")
    }
    $innoAttempt = @{
        Name = "Inno silent install"
        Args = @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/DIR=$TargetDir")
    }

    if ($kind -eq "inno") {
        $attempts = @($innoAttempt, $nsisAttempt)
    } else {
        $attempts = @($nsisAttempt, $innoAttempt)
    }

    foreach ($attempt in $attempts) {
        Write-Step "Running $($attempt.Name)"
        $process = Start-Process -FilePath $InstallerPath -ArgumentList $attempt.Args -Wait -PassThru
        if ($process.ExitCode -eq 0) {
            Start-Sleep -Seconds 2
            $exe = Get-AppExecutable $TargetDir
            if ($exe) {
                Write-Step "Whimbox app installed: $exe"
                return $exe
            }
            Write-Warn "$($attempt.Name) exited successfully, but app executable was not found."
        } else {
            Write-Warn "$($attempt.Name) failed with exit code $($process.ExitCode)."
        }
    }

    throw "Unable to install Whimbox app into $TargetDir"
}

function Get-LatestReleaseDownloads {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $releaseResponse = Invoke-GitHubApi "https://api.github.com/repos/$Repo/releases?per_page=30"
    $releases = @($releaseResponse)
    if (-not $releases -or $releases.Count -eq 0) {
        throw "Could not find any releases in $Repo"
    }

    $wheelPattern = "^whimbox-\d+\.\d+\.\d+-py3-none-any\.whl$"
    $setupPattern = "^whimbox_app-setup-\d+\.\d+\.\d+\.exe$"

    $wheel = $null
    $wheelRelease = $null
    $setup = $null
    $setupRelease = $null

    foreach ($release in $releases) {
        $candidate = $release.assets |
            Where-Object { $_.name -match $wheelPattern } |
            Select-Object -First 1
        if ($candidate) {
            $wheel = $candidate
            $wheelRelease = $release
            break
        }
    }

    foreach ($release in $releases) {
        $candidate = $release.assets |
            Where-Object { $_.name -match $setupPattern } |
            Select-Object -First 1
        if ($candidate) {
            $setup = $candidate
            $setupRelease = $release
            break
        }
    }

    if (-not $wheel -or -not $setup) {
        $assetNames = ($releases | ForEach-Object {
            $tag = $_.tag_name
            $names = ($_.assets | ForEach-Object { $_.name }) -join ", "
            if ([string]::IsNullOrWhiteSpace($names)) {
                $names = "(no assets)"
            }
            "${tag}: $names"
        }) -join "; "

        if (-not $wheel) {
            throw "Could not find a Whimbox backend wheel asset in recent $Repo releases. Assets: $assetNames"
        }
        throw "Could not find a Whimbox app setup asset in recent $Repo releases. Assets: $assetNames"
    }

    return @{
        ReleaseTag = $wheelRelease.tag_name
        WheelReleaseTag = $wheelRelease.tag_name
        SetupReleaseTag = $setupRelease.tag_name
        WheelName = $wheel.name
        WheelUrl = $wheel.browser_download_url
        SetupName = $setup.name
        SetupUrl = $setup.browser_download_url
    }
}

function Get-ScriptsZipUrl {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $repoInfo = Invoke-GitHubApi "https://api.github.com/repos/$Repo"
    $branch = $repoInfo.default_branch
    return @{
        Branch = $branch
        Url = "https://github.com/$Repo/archive/refs/heads/$branch.zip"
    }
}

function Find-ScriptsSourceRoot {
    param([Parameter(Mandatory = $true)][string]$ExtractRoot)

    $docDir = Get-ChildItem -LiteralPath $ExtractRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @("doc", "docs") } |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1

    if ($docDir) {
        return $docDir.Parent.FullName
    }

    $jsonRoot = Get-ChildItem -LiteralPath $ExtractRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            (Get-ChildItem -LiteralPath $_.FullName -File -Filter "*.json" -ErrorAction SilentlyContinue | Select-Object -First 1)
        } |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1

    if ($jsonRoot) {
        Write-Warn "Could not find doc/docs directory. Falling back to JSON script directory: $($jsonRoot.FullName)"
        return $jsonRoot.FullName
    }

    throw "Could not find a doc/docs directory or script JSON directory in extracted WhimboxScripts ZIP."
}

function Ensure-EmbeddedPython {
    param([Parameter(Mandatory = $true)][string]$AppDir)

    $pythonDir = Join-Path $AppDir "python-embedded"
    $pythonExe = Join-Path $pythonDir "python.exe"
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        $zip = Join-Path $AppDir "resources\assets\Python312.zip"
        if (-not (Test-Path -LiteralPath $zip)) {
            throw "Embedded Python was not found and Python312.zip is missing: $zip"
        }
        Write-Step "Extracting embedded Python from $zip"
        Ensure-Directory $pythonDir
        Expand-Archive -LiteralPath $zip -DestinationPath $pythonDir -Force
    }

    if (-not (Test-Path -LiteralPath $pythonExe)) {
        throw "Embedded Python executable was not found: $pythonExe"
    }

    return @{
        PythonDir = $pythonDir
        PythonExe = $pythonExe
        ScriptsDir = Join-Path $pythonDir "Scripts"
    }
}

function Invoke-EmbeddedPython {
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [Parameter(Mandatory = $true)][string]$PythonDir,
        [Parameter(Mandatory = $true)][string]$PythonScriptsDir,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutMilliseconds = 600000
    )

    $quoteArg = {
        param([string]$Value)
        if ($Value -notmatch '[\s"]') {
            return $Value
        }
        return '"' + ($Value -replace '"', '\"') + '"'
    }

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PythonExe
    $psi.Arguments = (($Arguments | ForEach-Object { & $quoteArg $_ }) -join " ")
    $psi.WorkingDirectory = Split-Path -Parent $PythonExe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.EnvironmentVariables["PYTHONNOUSERSITE"] = "1"
    $psi.EnvironmentVariables["PYTHONPATH"] = ""
    $psi.EnvironmentVariables["PYTHONHOME"] = $PythonDir
    $psi.EnvironmentVariables["PYTHONUNBUFFERED"] = "1"
    $psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"
    $psi.EnvironmentVariables["PATH"] = "$PythonDir;$PythonScriptsDir;$($psi.EnvironmentVariables["PATH"])"

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($TimeoutMilliseconds)
    if (-not $finished) {
        try {
            $process.Kill()
        } catch {
        }
        throw "Embedded Python command timed out. Args: $($Arguments -join ' ')"
    }
    $process.WaitForExit()

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    foreach ($line in (($stdout, $stderr) -join "`n" -split "`r?`n")) {
        if ($line.Trim().Length -gt 0) {
            Write-Host "    $line"
        }
    }

    if ($process.ExitCode -ne 0) {
        $detail = (($stdout, $stderr) -join "`n").Trim()
        if (-not $detail) {
            $detail = "no output"
        }
        throw "Embedded Python command failed with exit code $($process.ExitCode). Args: $($Arguments -join ' '). Output: $detail"
    }
}

function Get-WheelPackageInfo {
    param([Parameter(Mandatory = $true)][string]$WheelPath)

    $fileName = Split-Path -Leaf $WheelPath
    if ($fileName -notmatch "^(?<package>.+?)-(?<version>\d+(?:\.\d+){1,3})-") {
        throw "Cannot parse wheel package name/version from: $fileName"
    }

    $packageName = $Matches.package
    $version = $Matches.version
    return @{
        PackageName = $packageName
        Version = $version
        NormalizedVersion = Normalize-VersionString $version
        EntryPoint = $packageName -replace "-", "_"
    }
}

function Get-InstalledPythonPackageVersion {
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [Parameter(Mandatory = $true)][string]$PythonDir,
        [Parameter(Mandatory = $true)][string]$PythonScriptsDir,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PythonExe
    $psi.Arguments = "-s -m pip show $PackageName"
    $psi.WorkingDirectory = Split-Path -Parent $PythonExe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.EnvironmentVariables["PYTHONNOUSERSITE"] = "1"
    $psi.EnvironmentVariables["PYTHONPATH"] = ""
    $psi.EnvironmentVariables["PYTHONHOME"] = $PythonDir
    $psi.EnvironmentVariables["PYTHONUNBUFFERED"] = "1"
    $psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"
    $psi.EnvironmentVariables["PATH"] = "$PythonDir;$PythonScriptsDir;$($psi.EnvironmentVariables["PATH"])"

    try {
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $psi
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit(120000)
        if (-not $finished) {
            try {
                $process.Kill()
            } catch {
            }
            return $null
        }

        if ($process.ExitCode -ne 0) {
            return $null
        }

        $stdout = $stdoutTask.Result
        foreach ($line in ($stdout -split "`r?`n")) {
            if ($line -match "^Version:\s*(?<version>.+?)\s*$") {
                return Normalize-VersionString $Matches.version
            }
        }
    } catch {
        return $null
    }

    return $null
}

function Get-CurrentBackendVersionForWheel {
    param(
        [Parameter(Mandatory = $true)][string]$AppDir,
        [Parameter(Mandatory = $true)][hashtable]$WheelPackage
    )

    try {
        $python = Ensure-EmbeddedPython $AppDir
        return Get-InstalledPythonPackageVersion `
            -PythonExe $python.PythonExe `
            -PythonDir $python.PythonDir `
            -PythonScriptsDir $python.ScriptsDir `
            -PackageName $WheelPackage.PackageName
    } catch {
        return $null
    }
}

function Write-BackendStatusFromWheel {
    param([Parameter(Mandatory = $true)][string]$WheelPath)

    $package = Get-WheelPackageInfo $WheelPath
    $statusDir = Split-Path -Parent $BackendStatusFile
    Ensure-Directory $statusDir

    $status = @{
        backendStatus = @{
            installed = $true
            version = $package.Version
            installedAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
            packageName = $package.PackageName
            entryPoint = $package.EntryPoint
        }
    }

    Write-Step "Updating backend status store: $BackendStatusFile"
    $statusJson = $status | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($BackendStatusFile, $statusJson, [Text.UTF8Encoding]::new($false))
}

function Install-BackendWheelCodeLevel {
    param(
        [Parameter(Mandatory = $true)][string]$AppDir,
        [Parameter(Mandatory = $true)][string]$WheelPath
    )

    if (-not (Test-Path -LiteralPath $WheelPath)) {
        throw "Wheel file not found: $WheelPath"
    }

    $package = Get-WheelPackageInfo $WheelPath
    $python = Ensure-EmbeddedPython $AppDir
    $currentVersion = Get-InstalledPythonPackageVersion `
        -PythonExe $python.PythonExe `
        -PythonDir $python.PythonDir `
        -PythonScriptsDir $python.ScriptsDir `
        -PackageName $package.PackageName

    if ($currentVersion -and $currentVersion -eq $package.NormalizedVersion) {
        Write-Step "Backend package $($package.PackageName) is already version $($package.Version); skipping wheel install."
        Write-BackendStatusFromWheel -WheelPath $WheelPath
        return
    }

    Write-Step "Updating backend at code level, matching launcher:install-whl behavior."
    Stop-ProcessesUnderPath (Join-Path $AppDir "python-embedded")

    $pipSources = @(
        "https://mirrors.ustc.edu.cn/pypi/simple/",
        "https://pypi.tuna.tsinghua.edu.cn/simple/",
        "https://mirrors.cloud.tencent.com/pypi/simple/",
        "https://mirrors.aliyun.com/pypi/simple/"
    )

    $installed = $false
    $lastError = $null
    foreach ($source in $pipSources) {
        try {
            Write-Step "Trying pip source: $source"
            Invoke-EmbeddedPython `
                -PythonExe $python.PythonExe `
                -PythonDir $python.PythonDir `
                -PythonScriptsDir $python.ScriptsDir `
                -Arguments @("-s", "-m", "pip", "install", "-i", $source, "setuptools")

            Invoke-EmbeddedPython `
                -PythonExe $python.PythonExe `
                -PythonDir $python.PythonDir `
                -PythonScriptsDir $python.ScriptsDir `
                -Arguments @("-s", "-m", "pip", "install", "-i", $source, $WheelPath)

            $installed = $true
            break
        } catch {
            $lastError = $_
            Write-Warn "Pip source failed: $source. $($_.Exception.Message)"
        }
    }

    if (-not $installed) {
        throw "Backend wheel install failed. Last error: $lastError"
    }

    Write-BackendStatusFromWheel -WheelPath $WheelPath
}

function Wait-TcpPort {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $iar = $client.BeginConnect($HostName, $Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(1000, $false)) {
                $client.EndConnect($iar)
                return $true
            }
        } catch {
        } finally {
            $client.Close()
        }
        Start-Sleep -Seconds 1
    }

    return $false
}

function Receive-WebSocketText {
    param(
        [Parameter(Mandatory = $true)][System.Net.WebSockets.ClientWebSocket]$Client,
        [Parameter(Mandatory = $true)][System.Threading.CancellationToken]$Token
    )

    $buffer = New-Object byte[] 8192
    $builder = New-Object Text.StringBuilder
    do {
        $segment = [ArraySegment[byte]]::new($buffer)
        $result = $Client.ReceiveAsync($segment, $Token).GetAwaiter().GetResult()
        if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
            throw "WebSocket closed before response."
        }
        [void]$builder.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
    } until ($result.EndOfMessage)

    return $builder.ToString()
}

function Invoke-WhimboxRpcRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutSeconds = 60
    )

    $client = [Net.WebSockets.ClientWebSocket]::new()
    $cts = [Threading.CancellationTokenSource]::new()
    $cts.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
    $requestId = 1

    try {
        $uri = [Uri]"ws://127.0.0.1:$RpcPort"
        $client.ConnectAsync($uri, $cts.Token).GetAwaiter().GetResult()
        $payload = @{
            jsonrpc = "2.0"
            id = $requestId
            method = $Method
            params = $Params
        } | ConvertTo-Json -Depth 10 -Compress

        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $segment = [ArraySegment[byte]]::new($bytes)
        $client.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()

        while ($true) {
            $text = Receive-WebSocketText -Client $client -Token $cts.Token
            $message = $text | ConvertFrom-Json
            $idProperty = $message.PSObject.Properties["id"]
            if (-not $idProperty -or [int]$message.id -ne $requestId) {
                continue
            }

            $errorProperty = $message.PSObject.Properties["error"]
            if ($errorProperty -and $message.error) {
                throw ($message.error | ConvertTo-Json -Depth 10 -Compress)
            }

            $resultProperty = $message.PSObject.Properties["result"]
            if ($resultProperty) {
                return $message.result
            }
            return $null
        }
    } finally {
        if ($client.State -eq [Net.WebSockets.WebSocketState]::Open) {
            $client.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        }
        $client.Dispose()
        $cts.Dispose()
    }
}

function Restore-Backups {
    param(
        [bool]$InstallDirExisted,
        [bool]$BackendStatusExisted,
        [bool]$FullAppBackupCreated,
        [bool]$ScriptsDirExisted,
        [bool]$ScriptsBackupCreated,
        [bool]$StopBeforeRestore
    )

    Write-Warn "A failure occurred. Trying to restore backups."
    if ($StopBeforeRestore) {
        Stop-ProcessesUnderPath $InstallDir
    }

    if ($FullAppBackupCreated -and $InstallDirExisted -and (Test-Path -LiteralPath $InstallBackupDir)) {
        if (Test-Path -LiteralPath $InstallDir) {
            Remove-PathRobust $InstallDir
        }
        Ensure-Directory $InstallDir
        Copy-DirectoryContents -Source $InstallBackupDir -Destination $InstallDir -Mirror
    } elseif ($FullAppBackupCreated -and -not $InstallDirExisted -and (Test-Path -LiteralPath $InstallDir)) {
        Remove-PathRobust $InstallDir
    } elseif ($ScriptsBackupCreated -and (Test-Path -LiteralPath $ScriptsBackupDir)) {
        if (Test-Path -LiteralPath $TargetScriptsDir) {
            Remove-PathRobust $TargetScriptsDir
        }
        Ensure-Directory $TargetScriptsDir
        Copy-DirectoryContents -Source $ScriptsBackupDir -Destination $TargetScriptsDir -Mirror
    } elseif (-not $ScriptsDirExisted -and (Test-Path -LiteralPath $TargetScriptsDir)) {
        Remove-PathRobust $TargetScriptsDir
    }

    if ($BackendStatusExisted -and (Test-Path -LiteralPath $BackendStatusBackupFile)) {
        Ensure-Directory (Split-Path -Parent $BackendStatusFile)
        Copy-Item -LiteralPath $BackendStatusBackupFile -Destination $BackendStatusFile -Force
    } elseif (-not $BackendStatusExisted -and (Test-Path -LiteralPath $BackendStatusFile)) {
        Remove-PathRobust $BackendStatusFile
    }
}

$success = $false
$installDirExisted = Test-Path -LiteralPath $InstallDir
$scriptsDirExisted = Test-Path -LiteralPath $TargetScriptsDir
$backendStatusExisted = Test-Path -LiteralPath $BackendStatusFile
$fullAppBackupCreated = $false
$scriptsBackupCreated = $false
$stopBeforeRestore = $false

try {
    Ensure-Directory $TempRoot
    Ensure-Directory $DownloadDir
    Ensure-Directory $ExtractDir
    Ensure-Directory $BackupRoot

    Write-Step "Fetching latest Whimbox release info from GitHub."
    $releaseDownloads = Get-LatestReleaseDownloads -Repo $WhimboxRepo
    Write-Step "Latest backend release: $($releaseDownloads.WheelReleaseTag) ($($releaseDownloads.WheelName))"
    if ($releaseDownloads.SetupReleaseTag -eq $releaseDownloads.WheelReleaseTag) {
        Write-Step "App setup release: $($releaseDownloads.SetupReleaseTag) ($($releaseDownloads.SetupName))"
    } else {
        Write-Warn "Latest backend release has no app setup asset; using setup from release $($releaseDownloads.SetupReleaseTag) ($($releaseDownloads.SetupName))."
    }

    $wheelPath = Join-Path $DownloadDir $releaseDownloads.WheelName
    $setupPath = Join-Path $DownloadDir $releaseDownloads.SetupName
    $setupVersion = Get-SetupVersionFromName $releaseDownloads.SetupName
    $currentAppVersion = Get-InstalledAppVersion $InstallDir
    $shouldInstallApp = -not ($currentAppVersion -and $currentAppVersion -eq $setupVersion)
    $wheelPackage = Get-WheelPackageInfo $wheelPath
    $currentBackendVersion = $null
    if (-not $shouldInstallApp) {
        $currentBackendVersion = Get-CurrentBackendVersionForWheel -AppDir $InstallDir -WheelPackage $wheelPackage
    }
    $shouldInstallBackend = $shouldInstallApp -or -not ($currentBackendVersion -and $currentBackendVersion -eq $wheelPackage.NormalizedVersion)

    if ($shouldInstallBackend) {
        Download-File -Uri $releaseDownloads.WheelUrl -Destination $wheelPath
    } else {
        Write-Step "Backend package $($wheelPackage.PackageName) is already version $($wheelPackage.Version); skipping wheel download and install."
    }

    if ($shouldInstallApp) {
        Download-File -Uri $releaseDownloads.SetupUrl -Destination $setupPath
    } else {
        Write-Step "Whimbox app is already version $currentAppVersion; skipping setup download and installer."
    }

    Write-Step "Fetching latest WhimboxScripts ZIP info from GitHub."
    $scriptsZip = Get-ScriptsZipUrl -Repo $ScriptsRepo
    $scriptsZipPath = Join-Path $DownloadDir ("WhimboxScripts-{0}.zip" -f $scriptsZip.Branch)
    Download-File -Uri $scriptsZip.Url -Destination $scriptsZipPath

    if ($shouldInstallApp -or $shouldInstallBackend) {
        Stop-ProcessesUnderPath $InstallDir
        $stopBeforeRestore = $true
    } else {
        Write-Step "App and backend are already current; leaving running Whimbox processes open."
    }

    if ($installDirExisted -and ($shouldInstallApp -or $shouldInstallBackend)) {
        Write-Step "Backing up existing app directory: $InstallDir"
        Copy-DirectoryContents -Source $InstallDir -Destination $InstallBackupDir -Mirror
        $fullAppBackupCreated = $true
    } elseif ($scriptsDirExisted) {
        Write-Step "Backing up existing scripts directory: $TargetScriptsDir"
        Copy-DirectoryContents -Source $TargetScriptsDir -Destination $ScriptsBackupDir -Mirror
        $scriptsBackupCreated = $true
    }

    if ($backendStatusExisted) {
        Write-Step "Backing up backend status store: $BackendStatusFile"
        Copy-Item -LiteralPath $BackendStatusFile -Destination $BackendStatusBackupFile -Force
    }

    if ($shouldInstallApp) {
        $appExe = Invoke-WhimboxInstaller -InstallerPath $setupPath -TargetDir $InstallDir
    } else {
        $appExe = Get-AppExecutable $InstallDir
    }

    Write-Step "Extracting WhimboxScripts ZIP."
    Expand-Archive -LiteralPath $scriptsZipPath -DestinationPath $ExtractDir -Force
    $scriptsSourceRoot = Find-ScriptsSourceRoot -ExtractRoot $ExtractDir
    Write-Step "Copying scripts from $scriptsSourceRoot to $TargetScriptsDir"
    Copy-DirectoryContents -Source $scriptsSourceRoot -Destination $TargetScriptsDir

    if ($shouldInstallBackend) {
        Install-BackendWheelCodeLevel -AppDir $InstallDir -WheelPath $wheelPath
    } else {
        Write-BackendStatusFromWheel -WheelPath $wheelPath
    }

    if (-not $SkipAppLaunch) {
        $appExe = Get-AppExecutable $InstallDir
        if (-not $appExe) {
            throw "Whimbox app executable not found after install."
        }

        $rpcAlreadyAvailable = $false
        if (-not $SkipScriptRefresh) {
            $rpcAlreadyAvailable = Wait-TcpPort -HostName "127.0.0.1" -Port $RpcPort -TimeoutSeconds 2
        }

        if ($rpcAlreadyAvailable) {
            Write-Step "Whimbox RPC is already available; using the running app."
        } else {
            Write-Step "Launching Whimbox app: $appExe"
            Start-Process -FilePath $appExe -WorkingDirectory (Split-Path -Parent $appExe) | Out-Null
        }

        if (-not $SkipScriptRefresh) {
            Write-Step "Waiting for Whimbox RPC on ws://127.0.0.1:$RpcPort"
            if ($rpcAlreadyAvailable -or (Wait-TcpPort -HostName "127.0.0.1" -Port $RpcPort -TimeoutSeconds 90)) {
                Write-Step "Refreshing scripts through JSON-RPC method: script.refresh"
                Invoke-WhimboxRpcRequest -Method "script.refresh" -Params @{} -TimeoutSeconds 60 | Out-Null
                Write-Step "Script refresh request completed."
            } else {
                Write-Warn "RPC port did not open. App was launched, but script.refresh could not be sent automatically."
            }
        }
    }

    $success = $true
    Write-Step "Update completed."
} catch {
    $failure = $_
    try {
        Restore-Backups `
            -InstallDirExisted $installDirExisted `
            -BackendStatusExisted $backendStatusExisted `
            -FullAppBackupCreated $fullAppBackupCreated `
            -ScriptsDirExisted $scriptsDirExisted `
            -ScriptsBackupCreated $scriptsBackupCreated `
            -StopBeforeRestore $stopBeforeRestore
        Write-Warn "Backup restore completed."
        if (Test-Path -LiteralPath $BackupRoot) {
            Remove-PathRobust $BackupRoot
        }
    } catch {
        Write-Warn "Backup restore failed. Backup path kept at: $BackupRoot"
        Write-Warn "Restore error: $_"
    }
    throw $failure
} finally {
    if ($success) {
        if (Test-Path -LiteralPath $BackupRoot) {
            Remove-PathRobust $BackupRoot
        }
    }

    if (Test-Path -LiteralPath $TempRoot) {
        Remove-PathRobust $TempRoot
    }
}
