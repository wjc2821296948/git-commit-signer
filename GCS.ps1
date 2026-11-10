[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('scan', 'doctor', 'help')]
    [string]$Command = 'scan',

    [string]$ExpectedLogin,

    [string]$OutputDirectory = (Join-Path $env:LOCALAPPDATA 'GitCommitSigner\reports')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Resolve-Executable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$FallbackPaths = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command -and $command.Source) {
        return $command.Source
    }

    foreach ($candidate in $FallbackPaths) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Invoke-Gh {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = @(& $script:GhPath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $details = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        throw "GitHub CLI command failed (exit $exitCode): $details"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Get-GhPagedJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    # Ask gh to paginate normally, but let jq encode each repository record as
    # one Base64 line. This avoids parsing one large nested JSON document with
    # Windows PowerShell 5.1's legacy JavaScriptSerializer implementation.
    $result = Invoke-Gh -Arguments $Arguments
    $items = New-Object System.Collections.Generic.List[object]
    $recordNumber = 0

    foreach ($line in @($result.Output)) {
        $encoded = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($encoded)) {
            continue
        }

        if ($encoded -notmatch '^[A-Za-z0-9+/]+={0,2}$') {
            throw "GitHub CLI returned an unexpected paginated record at position $($recordNumber + 1). The response was not treated as repository data."
        }

        try {
            $bytes = [Convert]::FromBase64String($encoded)
            $jsonText = [System.Text.Encoding]::UTF8.GetString($bytes)
            $item = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
        }
        catch {
            throw "Could not decode GitHub repository record $($recordNumber + 1). Details: $($_.Exception.Message)"
        }

        if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.full_name)) {
            throw "GitHub returned an empty or invalid repository record at position $($recordNumber + 1)."
        }

        $items.Add($item)
        $recordNumber++
    }

    return $items.ToArray()
}

function Get-AuthenticatedLogin {
    $result = Invoke-Gh -Arguments @('api', 'user', '--jq', '.login')
    $login = (($result.Output | ForEach-Object { [string]$_ }) -join '').Trim()

    if ([string]::IsNullOrWhiteSpace($login)) {
        throw 'GitHub CLI did not return an authenticated username.'
    }

    return $login
}

function Get-RepositoryInventory {
    param([Parameter(Mandatory = $true)][string]$Login)

    Write-Info 'Retrieving all repositories visible to the authenticated GitHub account...'
    $endpoint = '/user/repos?per_page=100&affiliation=owner%2Ccollaborator%2Corganization_member&visibility=all&sort=full_name&direction=asc'
    $rawRepositories = Get-GhPagedJson -Arguments @(
        'api',
        '--paginate',
        '--jq',
        '.[] | @base64',
        $endpoint
    )

    $seen = @{}
    $inventory = New-Object System.Collections.Generic.List[object]

    foreach ($repo in $rawRepositories) {
        if ($null -eq $repo -or [string]::IsNullOrWhiteSpace([string]$repo.full_name)) {
            continue
        }

        $fullName = [string]$repo.full_name
        if ($seen.ContainsKey($fullName)) {
            continue
        }
        $seen[$fullName] = $true

        $ownerLogin = [string]$repo.owner.login
        $isOwned = $ownerLogin -ieq $Login
        $isFork = [bool]$repo.fork
        $isArchived = [bool]$repo.archived
        $canPush = $false
        $canAdmin = $false

        if ($null -ne $repo.permissions) {
            $canPush = [bool]$repo.permissions.push
            $canAdmin = [bool]$repo.permissions.admin
        }

        if ($isArchived) {
            $relationship = 'Archived'
        }
        elseif ($isOwned -and $isFork) {
            $relationship = 'OwnedFork'
        }
        elseif ($isOwned) {
            $relationship = 'Owned'
        }
        elseif ($isFork) {
            $relationship = 'AccessibleFork'
        }
        else {
            $relationship = 'CollaboratorOrOrganizationMember'
        }

        $eligibleForFutureRewrite = $isOwned -and $canPush -and (-not $isArchived)
        $visibility = [string]$repo.visibility
        if ([string]::IsNullOrWhiteSpace($visibility)) {
            if ([bool]$repo.private) {
                $visibility = 'private'
            }
            else {
                $visibility = 'public'
            }
        }

        $inventory.Add([pscustomobject]@{
            Id                         = [long]$repo.id
            Name                       = [string]$repo.name
            FullName                   = $fullName
            Owner                      = $ownerLogin
            Visibility                 = $visibility
            Archived                   = $isArchived
            Fork                       = $isFork
            Relationship               = $relationship
            DefaultBranch              = [string]$repo.default_branch
            CanPush                    = $canPush
            CanAdmin                   = $canAdmin
            OwnedByAuthenticatedUser   = $isOwned
            EligibleForFutureRewrite   = $eligibleForFutureRewrite
            UpdatedAt                  = [string]$repo.updated_at
            HtmlUrl                    = [string]$repo.html_url
            CloneUrl                   = [string]$repo.clone_url
        })
    }

    return @($inventory | Sort-Object FullName)
}

function Write-ScanReports {
    param(
        [Parameter(Mandatory = $true)][object[]]$Repositories,
        [Parameter(Mandatory = $true)][string]$Login,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    $timestamp = Get-Date
    $jsonPath = Join-Path $Directory 'repositories.json'
    $csvPath = Join-Path $Directory 'scan-report.csv'
    $summaryPath = Join-Path $Directory 'summary.json'

    $json = ConvertTo-Json -InputObject @($Repositories) -Depth 8
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($jsonPath, $json, $utf8NoBom)

    if ($Repositories.Count -gt 0) {
        $Repositories |
            Select-Object FullName, Visibility, Relationship, Archived, Fork,
                DefaultBranch, CanPush, CanAdmin, EligibleForFutureRewrite,
                UpdatedAt, HtmlUrl |
            Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    }
    else {
        'FullName,Visibility,Relationship,Archived,Fork,DefaultBranch,CanPush,CanAdmin,EligibleForFutureRewrite,UpdatedAt,HtmlUrl' |
            Set-Content -LiteralPath $csvPath -Encoding UTF8
    }

    $summary = [pscustomobject]@{
        SchemaVersion       = '0.1'
        GeneratedAt         = $timestamp.ToString('o')
        AuthenticatedLogin  = $Login
        RepositoryCount     = $Repositories.Count
        PublicCount         = @($Repositories | Where-Object { $_.Visibility -eq 'public' }).Count
        PrivateCount        = @($Repositories | Where-Object { $_.Visibility -eq 'private' }).Count
        InternalCount       = @($Repositories | Where-Object { $_.Visibility -eq 'internal' }).Count
        ArchivedCount       = @($Repositories | Where-Object { $_.Archived }).Count
        ForkCount           = @($Repositories | Where-Object { $_.Fork }).Count
        OwnedCount          = @($Repositories | Where-Object { $_.OwnedByAuthenticatedUser }).Count
        FutureRewriteEligibleCount = @($Repositories | Where-Object { $_.EligibleForFutureRewrite }).Count
        ReadOnly            = $true
        Reports             = [pscustomobject]@{
            Json = $jsonPath
            Csv  = $csvPath
        }
    }

    [System.IO.File]::WriteAllText(
        $summaryPath,
        (ConvertTo-Json -InputObject $summary -Depth 8),
        $utf8NoBom
    )

    return [pscustomobject]@{
        JsonPath    = $jsonPath
        CsvPath     = $csvPath
        SummaryPath = $summaryPath
        Summary     = $summary
    }
}

function Invoke-Doctor {
    Write-Host ''
    Write-Host 'Git Commit Signer - Environment Check' -ForegroundColor White
    Write-Host '-------------------------------------' -ForegroundColor DarkGray

    $gitPath = Resolve-Executable -Name 'git.exe' -FallbackPaths @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe'
    )
    $ghPath = Resolve-Executable -Name 'gh.exe' -FallbackPaths @(
        'D:\GitHub-CLI\gh.exe',
        (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe')
    )
    $sshPath = Resolve-Executable -Name 'ssh.exe' -FallbackPaths @(
        'C:\Windows\System32\OpenSSH\ssh.exe'
    )

    [pscustomobject]@{ Component = 'PowerShell'; Status = $PSVersionTable.PSVersion.ToString(); Path = $PSHOME }
    [pscustomobject]@{ Component = 'Git'; Status = $(if ($gitPath) { 'Found' } else { 'Missing' }); Path = $gitPath }
    [pscustomobject]@{ Component = 'GitHub CLI'; Status = $(if ($ghPath) { 'Found' } else { 'Missing' }); Path = $ghPath }
    [pscustomobject]@{ Component = 'OpenSSH'; Status = $(if ($sshPath) { 'Found' } else { 'Missing' }); Path = $sshPath }

    if ($ghPath) {
        $script:GhPath = $ghPath
        $auth = Invoke-Gh -Arguments @('auth', 'status') -AllowFailure
        if ($auth.ExitCode -eq 0) {
            Write-Host 'GitHub authentication: OK' -ForegroundColor Green
            $login = Get-AuthenticatedLogin
            Write-Host "Authenticated account: $login" -ForegroundColor Green
        }
        else {
            Write-Warn 'GitHub CLI is installed but not authenticated. Run: gh auth login'
        }
    }

    if ($gitPath) {
        $format = (& $gitPath config --global --get gpg.format 2>$null)
        $signingKey = (& $gitPath config --global --get user.signingkey 2>$null)
        $autoSign = (& $gitPath config --global --get commit.gpgsign 2>$null)
        Write-Host "Global gpg.format: $format"
        Write-Host "Global user.signingkey: $signingKey"
        Write-Host "Global commit.gpgsign: $autoSign"
    }

    $sshPublicKey = Join-Path $env:USERPROFILE '.ssh\id_ed25519.pub'
    if (Test-Path -LiteralPath $sshPublicKey -PathType Leaf) {
        Write-Host "SSH public signing key: Found ($sshPublicKey)" -ForegroundColor Green
    }
    else {
        Write-Warn "SSH public key not found at the expected path: $sshPublicKey"
    }
}

function Show-Help {
    @'
Git Commit Signer (GCS) - V0.1

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\GCS.ps1 scan
  powershell -NoProfile -ExecutionPolicy Bypass -File .\GCS.ps1 doctor

Commands:
  scan    Read-only inventory of repositories visible to the GitHub account.
  doctor  Check Git, GitHub CLI, OpenSSH, authentication, and signing configuration.
  help    Show this help.

Options:
  -ExpectedLogin <login>       Abort if the authenticated GitHub account differs.
  -OutputDirectory <path>      Report directory (default: %LOCALAPPDATA%\GitCommitSigner\reports).

V0.1 is read-only. It does not inspect commit signatures, rewrite commits, modify refs,
change GitHub repository settings, or push to GitHub.
'@ | Write-Host
}

try {
    $script:GhPath = Resolve-Executable -Name 'gh.exe' -FallbackPaths @(
        'D:\GitHub-CLI\gh.exe',
        (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe')
    )

    switch ($Command) {
        'help' {
            Show-Help
            exit 0
        }
        'doctor' {
            Invoke-Doctor
            exit 0
        }
        'scan' {
            if (-not $script:GhPath) {
                throw 'GitHub CLI (gh) was not found. Install it or add gh.exe to PATH.'
            }

            $authStatus = Invoke-Gh -Arguments @('auth', 'status') -AllowFailure
            if ($authStatus.ExitCode -ne 0) {
                throw 'GitHub CLI is not authenticated. Run: gh auth login'
            }

            $login = Get-AuthenticatedLogin
            if ($ExpectedLogin -and $login -ine $ExpectedLogin) {
                throw "Authenticated account is '$login', but -ExpectedLogin requires '$ExpectedLogin'. Aborting."
            }

            Write-Host ''
            Write-Host 'Git Commit Signer - V0.1 Repository Discovery' -ForegroundColor White
            Write-Host 'READ-ONLY: no GitHub or Git history will be modified.' -ForegroundColor Yellow
            Write-Host "Authenticated as: $login" -ForegroundColor Green
            Write-Host ''

            $repositories = @(Get-RepositoryInventory -Login $login)
            $reports = Write-ScanReports -Repositories $repositories -Login $login -Directory $OutputDirectory

            Write-Host ''
            Write-Host 'Scan completed.' -ForegroundColor Green
            Write-Host "Repositories: $($reports.Summary.RepositoryCount)"
            Write-Host "Public:       $($reports.Summary.PublicCount)"
            Write-Host "Private:      $($reports.Summary.PrivateCount)"
            Write-Host "Internal:     $($reports.Summary.InternalCount)"
            Write-Host "Archived:     $($reports.Summary.ArchivedCount)"
            Write-Host "Owned:        $($reports.Summary.OwnedCount)"
            Write-Host "Future rewrite eligible (metadata only): $($reports.Summary.FutureRewriteEligibleCount)"
            Write-Host ''
            Write-Host "JSON: $($reports.JsonPath)"
            Write-Host "CSV:  $($reports.CsvPath)"
            Write-Host "Summary: $($reports.SummaryPath)"
            Write-Host ''
            Write-Warn 'V0.1 does not inspect commit signatures or rewrite commits. Those features are planned for later versions.'
        }
    }
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
