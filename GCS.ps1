[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('scan', 'audit', 'doctor', 'help')]
    [string]$Command = 'scan',

    [string]$ExpectedLogin,

    [ValidatePattern('^[^/\s]+/[^/\s]+$')]
    [string]$Repository,

    [ValidateRange(5, 600)]
    [int]$RequestTimeoutSeconds = 45,

    [ValidateRange(0, 5)]
    [int]$MaxRetries = 2,

    [string]$OutputDirectory = (Join-Path $env:LOCALAPPDATA 'GitCommitSigner\reports')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:RequestTimeoutSeconds = $RequestTimeoutSeconds
$script:MaxRetries = $MaxRetries
# Use a native Windows console control handler. It runs outside the PowerShell
# runspace and intercepts Ctrl+C before the PowerShell host stops the pipeline.
if ($null -eq ('GcsV021ConsoleCancellation' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class GcsV021ConsoleCancellation
{
    private enum ControlType : uint
    {
        CtrlC = 0,
        CtrlBreak = 1
    }

    private delegate bool ConsoleControlHandler(ControlType controlType);

    private static ConsoleControlHandler _handler;
    private static int _requested;

    [DllImport("Kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetConsoleCtrlHandler(ConsoleControlHandler handler, bool add);

    public static bool Requested
    {
        get { return Volatile.Read(ref _requested) != 0; }
    }

    public static bool Register()
    {
        Interlocked.Exchange(ref _requested, 0);

        if (_handler != null)
        {
            return true;
        }

        _handler = HandleConsoleControl;
        if (!SetConsoleCtrlHandler(_handler, true))
        {
            _handler = null;
            return false;
        }

        return true;
    }

    public static void Unregister()
    {
        if (_handler != null)
        {
            SetConsoleCtrlHandler(_handler, false);
            _handler = null;
        }
    }

    private static bool HandleConsoleControl(ControlType controlType)
    {
        if (controlType == ControlType.CtrlC || controlType == ControlType.CtrlBreak)
        {
            Interlocked.Exchange(ref _requested, 1);
            return true;
        }

        return false;
    }
}
'@ -ErrorAction Stop | Out-Null
}
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
        [switch]$AllowFailure,
        [ValidateRange(5, 600)][int]$TimeoutSeconds = $script:RequestTimeoutSeconds,
        [ValidateRange(0, 5)][int]$RetryCount = $script:MaxRetries
    )

    for ($attempt = 1; $attempt -le ($RetryCount + 1); $attempt++) {
        if ([GcsV021ConsoleCancellation]::Requested) {
            throw [System.OperationCanceledException]::new('Audit cancelled by Ctrl+C.')
        }

        $stdoutPath = [System.IO.Path]::GetTempFileName()
        $stderrPath = [System.IO.Path]::GetTempFileName()
        $process = $null

        try {
            # Start-Process lets GCS enforce a finite timeout and stop a stuck gh.exe.
            # Quote every argument because Start-Process joins ArgumentList into one string.
            $argumentLine = (@($Arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
            $process = Start-Process -FilePath $script:GhPath -ArgumentList $argumentLine -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop

            # Cache the process handle before waiting. Windows PowerShell 5.1 can otherwise
            # return $null for ExitCode when Start-Process uses -NoNewWindow with redirected streams.
            $null = $process.Handle

            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $process.WaitForExit(250)) {
                if ([GcsV021ConsoleCancellation]::Requested) {
                    try {
                        $process.Kill()
                        $null = $process.WaitForExit(5000)
                    }
                    catch {
                        # The process may have exited between the check and Kill().
                    }
                    throw [System.OperationCanceledException]::new('Audit cancelled by Ctrl+C.')
                }

                if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    try {
                        $process.Kill()
                        $null = $process.WaitForExit(5000)
                    }
                    catch {
                        # Ignore a race where the process exits as the timeout fires.
                    }
                    throw [System.TimeoutException]::new("GitHub CLI request exceeded the $TimeoutSeconds-second timeout.")
                }
            }

            $null = $process.WaitForExit()
            if ([GcsV021ConsoleCancellation]::Requested) {
                throw [System.OperationCanceledException]::new('Audit cancelled by Ctrl+C.')
            }
            $exitCode = $process.ExitCode
            $output = @()
            $errorText = ''

            if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
                $output = @(Get-Content -LiteralPath $stdoutPath)
            }
            if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
                $errorText = [System.IO.File]::ReadAllText($stderrPath).Trim()
            }

            if ($exitCode -ne 0 -and -not $AllowFailure) {
                $details = $errorText
                if ([string]::IsNullOrWhiteSpace($details)) {
                    $details = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
                }
                throw "GitHub CLI command failed (exit $exitCode): $details"
            }

            return [pscustomobject]@{
                ExitCode = $exitCode
                Output = $output
            }
        }
        catch [System.OperationCanceledException] {
            throw
        }
        catch {
            $message = [string]$_.Exception.Message
            if ($message -match '(?i)API rate limit|secondary rate limit|abuse detection') {
                throw
            }

            $isTransient = ($_.Exception -is [System.TimeoutException]) -or ($message -match '(?i)HTTP 5\d\d|HTTP 429|timed out|timeout|connection reset|connection refused|temporary failure|unexpected EOF|TLS handshake|no such host|proxyconnect|network is unreachable|server error')
            if ($AllowFailure -or -not $isTransient -or $attempt -gt $RetryCount) {
                throw
            }

            $delaySeconds = [Math]::Min(8, [Math]::Pow(2, ($attempt - 1)))
            Write-Warn "GitHub request failed; retrying in $delaySeconds second(s) ($attempt/$RetryCount). $message"
            Start-Sleep -Seconds $delaySeconds
        }
        finally {
            if ($null -ne $process) {
                $process.Dispose()
            }
            Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }

    throw 'GitHub CLI request failed after all retry attempts.'
}

function Get-GhPagedJson {
    param(
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [string]$ExpectedProperty,
        [string]$ProgressLabel = 'GitHub API',
        [ValidateRange(1, 100)][int]$PerPage = 100
    )

    # Fetch pages individually so progress is visible and every request has a timeout.
    $items = New-Object System.Collections.Generic.List[object]
    $page = 1
    $recordNumber = 0
    $separator = if ($Endpoint.Contains('?')) { '&' } else { '?' }

    while ($true) {
        if ([GcsV021ConsoleCancellation]::Requested) {
            throw [System.OperationCanceledException]::new('Audit cancelled by Ctrl+C.')
        }

        $pageEndpoint = "$Endpoint$separator" + "page=$page"
        Write-Host "  [API] $ProgressLabel - requesting page $page..." -ForegroundColor DarkGray
        $result = Invoke-Gh -Arguments @('api', '--jq', '.[] | @base64', $pageEndpoint)

        $pageRecordCount = 0
        foreach ($line in @($result.Output)) {
            $encoded = ([string]$line).Trim()
            if ([string]::IsNullOrWhiteSpace($encoded)) {
                continue
            }

            if ($encoded -notmatch '^[A-Za-z0-9+/]+={0,2}$') {
                throw "GitHub CLI returned an unexpected paginated record at position $($recordNumber + 1)."
            }

            try {
                $bytes = [Convert]::FromBase64String($encoded)
                $jsonText = [System.Text.Encoding]::UTF8.GetString($bytes)
                $item = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
            }
            catch {
                throw "Could not decode GitHub API record $($recordNumber + 1). Details: $($_.Exception.Message)"
            }

            if ($null -eq $item) {
                throw "GitHub returned an empty record at position $($recordNumber + 1)."
            }

            if ($ExpectedProperty) {
                $property = $item.PSObject.Properties[$ExpectedProperty]
                if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    throw "GitHub API record $($recordNumber + 1) is missing '$ExpectedProperty'."
                }
            }

            $items.Add($item)
            $recordNumber++
            $pageRecordCount++
        }

        Write-Host "  [API] $ProgressLabel - page $page returned $pageRecordCount record(s)." -ForegroundColor DarkGray
        if ($pageRecordCount -lt $PerPage) {
            break
        }

        $page++
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
    $rawRepositories = Get-GhPagedJson -Endpoint $endpoint -ExpectedProperty 'full_name' -ProgressLabel 'Repository inventory'

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


function Get-VerificationStatus {
    param([object]$Verification)

    if ($null -eq $Verification) {
        return 'Unavailable'
    }

    if ($Verification.verified -eq $true) {
        return 'Verified'
    }

    switch ([string]$Verification.reason) {
        'unsigned' { return 'Unsigned' }
        'unknown_key' { return 'UnknownKey' }
        'invalid' { return 'Invalid' }
        'unverified_email' { return 'UnverifiedEmail' }
        default { return 'Unverified' }
    }
}

function Get-RepositoryCommitAudit {
    param([Parameter(Mandatory = $true)][object]$Repository)

    $branchRows = New-Object System.Collections.Generic.List[object]
    $errorRows = New-Object System.Collections.Generic.List[object]
    $commitRecords = @{}
    $branchFailureCount = 0
    $rateLimitHit = $false
    $scanInterrupted = $false
    $branches = @()

    $branchesEndpoint = "/repos/$($Repository.FullName)/branches?per_page=100"
    try {
        $branches = @(Get-GhPagedJson -Endpoint $branchesEndpoint -ExpectedProperty 'name' -ProgressLabel "$($Repository.FullName) branches")
    }
    catch {
        $message = [string]$_.Exception.Message
        $rateLimitHit = ($message -match '(?i)rate limit|secondary rate|abuse detection')
        $scanInterrupted = ($_.Exception -is [System.OperationCanceledException]) -or [GcsV021ConsoleCancellation]::Requested
        $errorRows.Add([pscustomobject]@{
            Repository = $Repository.FullName
            Branch = ''
            Stage = $(if ($scanInterrupted) { 'Cancelled' } else { 'ListBranches' })
            Message = $message
        })
        return [pscustomobject]@{
            Branches = @()
            Commits = @()
            Errors = @($errorRows.ToArray())
            BranchCount = 0
            BranchFailureCount = 1
            RepositoryFailed = $true
            RateLimitHit = $rateLimitHit
            Interrupted = $scanInterrupted
        }
    }

    $branchIndex = 0
    foreach ($branch in $branches) {
        $branchIndex++
        $branchName = [string]$branch.name
        $branchHead = ''
        if ($null -ne $branch.commit) {
            $branchHead = [string]$branch.commit.sha
        }

        $branchRow = [pscustomobject]@{
            Repository = $Repository.FullName
            Branch = $branchName
            HeadSha = $branchHead
            Protected = [bool]$branch.protected
            CommitCount = 0
            Status = 'Pending'
        }
        $branchRows.Add($branchRow)

        try {
            $encodedRef = [Uri]::EscapeDataString($branchName)
            $commitsEndpoint = "/repos/$($Repository.FullName)/commits?sha=$encodedRef&per_page=100"
            Write-Host "  [Branch $branchIndex/$($branches.Count)] $branchName - reading commit history..." -ForegroundColor Gray
            $branchCommits = @(Get-GhPagedJson -Endpoint $commitsEndpoint -ExpectedProperty 'sha' -ProgressLabel "$($Repository.FullName) / $branchName")

            $branchRow.CommitCount = $branchCommits.Count
            $branchRow.Status = 'Scanned'

            foreach ($commit in $branchCommits) {
                $sha = [string]$commit.sha
                if ([string]::IsNullOrWhiteSpace($sha)) {
                    continue
                }

                if (-not $commitRecords.ContainsKey($sha)) {
                    $verification = $null
                    if ($null -ne $commit.commit) {
                        $verification = $commit.commit.verification
                    }
                    $verificationReason = ''
                    $verifiedAt = ''
                    $signaturePresent = $false
                    if ($null -ne $verification) {
                        $verificationReason = [string]$verification.reason
                        $verifiedAt = [string]$verification.verified_at
                        $signaturePresent = ($null -ne $verification.signature -and -not [string]::IsNullOrWhiteSpace([string]$verification.signature))
                    }
                    $parents = @()
                    if ($null -ne $commit.parents) {
                        $parents = @($commit.parents | ForEach-Object { [string]$_.sha })
                    }

                    $author = $commit.commit.author
                    $committer = $commit.commit.committer
                    $authorName = ''
                    $authorEmail = ''
                    $authorDate = ''
                    $committerName = ''
                    $committerEmail = ''
                    $committerDate = ''
                    $message = ''
                    if ($null -ne $author) {
                        $authorName = [string]$author.name
                        $authorEmail = [string]$author.email
                        $authorDate = [string]$author.date
                    }
                    if ($null -ne $committer) {
                        $committerName = [string]$committer.name
                        $committerEmail = [string]$committer.email
                        $committerDate = [string]$committer.date
                    }
                    if ($null -ne $commit.commit) {
                        $message = [string]$commit.commit.message
                    }

                    $branchNames = New-Object System.Collections.Generic.List[string]
                    $commitRecords[$sha] = [pscustomobject]@{
                        Repository = $Repository.FullName
                        CommitSha = $sha
                        ShortSha = $sha.Substring(0, [Math]::Min(7, $sha.Length))
                        VerificationStatus = (Get-VerificationStatus -Verification $verification)
                        VerificationReason = $verificationReason
                        VerifiedAt = $verifiedAt
                        SignaturePresent = $signaturePresent
                        AuthorName = $authorName
                        AuthorEmail = $authorEmail
                        AuthorDate = $authorDate
                        CommitterName = $committerName
                        CommitterEmail = $committerEmail
                        CommitterDate = $committerDate
                        ParentCount = $parents.Count
                        IsMergeCommit = ($parents.Count -gt 1)
                        Message = $message
                        HtmlUrl = [string]$commit.html_url
                        BranchNames = $branchNames
                    }
                }

                $record = $commitRecords[$sha]
                if (-not $record.BranchNames.Contains($branchName)) {
                    $record.BranchNames.Add($branchName)
                }
            }
        }
        catch {
            $branchFailureCount++
            $message = [string]$_.Exception.Message
            $wasCancelled = ($_.Exception -is [System.OperationCanceledException]) -or [GcsV021ConsoleCancellation]::Requested
            if ($wasCancelled) {
                $branchRow.Status = 'Interrupted'
                $scanInterrupted = $true
            }
            else {
                $branchRow.Status = 'Failed'
            }
            $rateLimitHit = ($message -match '(?i)rate limit|secondary rate|abuse detection')
            $errorRows.Add([pscustomobject]@{
                Repository = $Repository.FullName
                Branch = $branchName
                Stage = $(if ($wasCancelled) { 'Cancelled' } else { 'ListCommits' })
                Message = $message
            })
            if ($rateLimitHit -or $wasCancelled) {
                break
            }
        }
    }

    $commitRows = New-Object System.Collections.Generic.List[object]
    foreach ($record in $commitRecords.Values) {
        $commitRows.Add([pscustomobject]@{
            Repository = $record.Repository
            CommitSha = $record.CommitSha
            ShortSha = $record.ShortSha
            VerificationStatus = $record.VerificationStatus
            VerificationReason = $record.VerificationReason
            VerifiedAt = $record.VerifiedAt
            SignaturePresent = $record.SignaturePresent
            AuthorName = $record.AuthorName
            AuthorEmail = $record.AuthorEmail
            AuthorDate = $record.AuthorDate
            CommitterName = $record.CommitterName
            CommitterEmail = $record.CommitterEmail
            CommitterDate = $record.CommitterDate
            ParentCount = $record.ParentCount
            IsMergeCommit = $record.IsMergeCommit
            Branches = (@($record.BranchNames.ToArray()) -join ';')
            Message = $record.Message
            HtmlUrl = $record.HtmlUrl
        })
    }

    return [pscustomobject]@{
        Branches = @($branchRows.ToArray())
        Commits = @($commitRows.ToArray())
        Errors = @($errorRows.ToArray())
        BranchCount = $branchRows.Count
        BranchFailureCount = $branchFailureCount
        RepositoryFailed = ($branchFailureCount -gt 0)
        RateLimitHit = $rateLimitHit
        Interrupted = $scanInterrupted
    }
}

function Write-AuditReports {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Repositories,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Branches,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Commits,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Errors,
        [Parameter(Mandatory = $true)][string]$Login,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][int]$RepositoryFailureCount,
        [Parameter(Mandatory = $true)][int]$RepositoryAttemptedCount,
        [Parameter(Mandatory = $true)][bool]$ScanStoppedEarly,
        [string]$RepositoryFilter = '',
        [bool]$Cancelled = $false
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    $timestamp = Get-Date
    $branchesCsv = Join-Path $Directory 'branch-audit.csv'
    $commitsJson = Join-Path $Directory 'commit-signature-audit.json'
    $commitsCsv = Join-Path $Directory 'commit-signature-audit.csv'
    $errorsCsv = Join-Path $Directory 'audit-errors.csv'
    $summaryPath = Join-Path $Directory 'audit-summary.json'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    if ($Branches.Count -gt 0) {
        $Branches | Sort-Object Repository, Branch |
            Export-Csv -LiteralPath $branchesCsv -NoTypeInformation -Encoding UTF8
    }
    else {
        'Repository,Branch,HeadSha,Protected,CommitCount,Status' |
            Set-Content -LiteralPath $branchesCsv -Encoding UTF8
    }

    if ($Commits.Count -gt 0) {
        $Commits | Sort-Object Repository, CommitterDate, CommitSha |
            Export-Csv -LiteralPath $commitsCsv -NoTypeInformation -Encoding UTF8
    }
    else {
        'Repository,CommitSha,ShortSha,VerificationStatus,VerificationReason,VerifiedAt,SignaturePresent,AuthorName,AuthorEmail,AuthorDate,CommitterName,CommitterEmail,CommitterDate,ParentCount,IsMergeCommit,Branches,Message,HtmlUrl' |
            Set-Content -LiteralPath $commitsCsv -Encoding UTF8
    }

    $commitJson = ConvertTo-Json -InputObject @($Commits) -Depth 8
    [System.IO.File]::WriteAllText($commitsJson, $commitJson, $utf8NoBom)

    if ($Errors.Count -gt 0) {
        $Errors | Export-Csv -LiteralPath $errorsCsv -NoTypeInformation -Encoding UTF8
    }
    else {
        'Repository,Branch,Stage,Message' |
            Set-Content -LiteralPath $errorsCsv -Encoding UTF8
    }

    $summary = [pscustomobject]@{
        SchemaVersion = '0.2.1'
        GeneratedAt = $timestamp.ToString('o')
        RepositoryFilter = $RepositoryFilter
        RequestTimeoutSeconds = $script:RequestTimeoutSeconds
        MaxRetries = $script:MaxRetries
        Cancelled = $Cancelled
        AuthenticatedLogin = $Login
        RepositoryCount = $Repositories.Count
        RepositoryAttemptedCount = $RepositoryAttemptedCount
        RepositoryScannedCount = ($RepositoryAttemptedCount - $RepositoryFailureCount)
        RepositoryFailureCount = $RepositoryFailureCount
        RepositoryNotAttemptedCount = [Math]::Max(0, ($Repositories.Count - $RepositoryAttemptedCount))
        ScanStoppedEarly = $ScanStoppedEarly
        BranchCount = $Branches.Count
        BranchFailureCount = @($Branches | Where-Object { $_.Status -eq 'Failed' -or $_.Status -eq 'Interrupted' }).Count
        UniqueCommitCount = $Commits.Count
        VerifiedCount = @($Commits | Where-Object { $_.VerificationStatus -eq 'Verified' }).Count
        UnsignedCount = @($Commits | Where-Object { $_.VerificationStatus -eq 'Unsigned' }).Count
        UnknownKeyCount = @($Commits | Where-Object { $_.VerificationStatus -eq 'UnknownKey' }).Count
        InvalidCount = @($Commits | Where-Object { $_.VerificationStatus -eq 'Invalid' }).Count
        UnverifiedEmailCount = @($Commits | Where-Object { $_.VerificationStatus -eq 'UnverifiedEmail' }).Count
        OtherUnverifiedCount = @($Commits | Where-Object { $_.VerificationStatus -eq 'Unverified' }).Count
        VerificationUnavailableCount = @($Commits | Where-Object { $_.VerificationStatus -eq 'Unavailable' }).Count
        ErrorCount = $Errors.Count
        Complete = ($Errors.Count -eq 0 -and -not $ScanStoppedEarly)
        ReadOnly = $true
        Reports = [pscustomobject]@{
            BranchesCsv = $branchesCsv
            CommitsCsv = $commitsCsv
            CommitsJson = $commitsJson
            ErrorsCsv = $errorsCsv
        }
    }

    [System.IO.File]::WriteAllText(
        $summaryPath,
        (ConvertTo-Json -InputObject $summary -Depth 8),
        $utf8NoBom
    )

    return [pscustomobject]@{
        SummaryPath = $summaryPath
        Summary = $summary
        BranchesCsv = $branchesCsv
        CommitsCsv = $commitsCsv
        CommitsJson = $commitsJson
        ErrorsCsv = $errorsCsv
    }
}

function Invoke-Audit {
    param(
        [Parameter(Mandatory = $true)][string]$Login,
        [Parameter(Mandatory = $true)][string]$Directory,
        [string]$Repository
    )

    Write-Host ''
    Write-Host 'Git Commit Signer - V0.2.1 Commit Signature Audit' -ForegroundColor White
    Write-Host 'READ-ONLY: no Git refs, commits, or remote content will be modified.' -ForegroundColor Yellow
    Write-Host "Authenticated as: $Login" -ForegroundColor Green
    Write-Host "Per-request timeout: $($script:RequestTimeoutSeconds)s; retries: $($script:MaxRetries)" -ForegroundColor Gray
    if ($Repository) {
        Write-Host "Repository filter: $Repository" -ForegroundColor Cyan
    }
    Write-Host ''

    $allBranches = New-Object System.Collections.Generic.List[object]
    $allCommits = New-Object System.Collections.Generic.List[object]
    $allErrors = New-Object System.Collections.Generic.List[object]
    $repositoryFailureCount = 0
    $repositoryIndex = 0
    $scanStoppedEarly = $false
    $repositories = @()

    try {
        $repositories = @(Get-RepositoryInventory -Login $Login)
    }
    catch [System.OperationCanceledException] {
        $scanStoppedEarly = $true
        $allErrors.Add([pscustomobject]@{
            Repository = ''
            Branch = ''
            Stage = 'Cancelled'
            Message = 'Audit cancelled while retrieving the repository inventory. No repository scan was completed.'
        })
    }

    if (-not $scanStoppedEarly -and $Repository) {
        $repositories = @($repositories | Where-Object { $_.FullName -ieq $Repository })
        if ($repositories.Count -eq 0) {
            throw "Repository '$Repository' is not visible to the authenticated account '$Login'."
        }
    }

    if (-not $scanStoppedEarly) {
        foreach ($repositoryItem in $repositories) {
            $repositoryIndex++
            Write-Host "[$repositoryIndex/$($repositories.Count)] $($repositoryItem.FullName)" -ForegroundColor Cyan

            $result = Get-RepositoryCommitAudit -Repository $repositoryItem
            if ($result.RepositoryFailed) {
                $repositoryFailureCount++
            }

            foreach ($branchRow in @($result.Branches)) {
                $allBranches.Add($branchRow)
            }
            foreach ($commitRow in @($result.Commits)) {
                $allCommits.Add($commitRow)
            }
            foreach ($errorRow in @($result.Errors)) {
                $allErrors.Add($errorRow)
            }

            Write-Host "  branches: $($result.BranchCount); unique commits: $($result.Commits.Count); branch failures: $($result.BranchFailureCount)"

            if ($result.Interrupted) {
                $scanStoppedEarly = $true
                $allErrors.Add([pscustomobject]@{
                    Repository = $repositoryItem.FullName
                    Branch = ''
                    Stage = 'ScanStopped'
                    Message = 'The user cancelled the audit. Completed repository and branch results were saved; the current scan is incomplete.'
                })
                break
            }

            if ($result.RateLimitHit) {
                $scanStoppedEarly = $true
                $allErrors.Add([pscustomobject]@{
                    Repository = $repositoryItem.FullName
                    Branch = ''
                    Stage = 'ScanStopped'
                    Message = 'GitHub API rate limiting was detected. Remaining repositories were not scanned; rerun the audit after the limit resets.'
                })
                break
            }
        }
    }

    $wasCancelled = [GcsV021ConsoleCancellation]::Requested
    $reportParameters = @{
        Repositories = $repositories
        Branches = @($allBranches.ToArray())
        Commits = @($allCommits.ToArray())
        Errors = @($allErrors.ToArray())
        Login = $Login
        Directory = $Directory
        RepositoryFailureCount = $repositoryFailureCount
        RepositoryAttemptedCount = $repositoryIndex
        ScanStoppedEarly = $scanStoppedEarly
        RepositoryFilter = $Repository
        Cancelled = $wasCancelled
    }
    $reports = Write-AuditReports @reportParameters

    Write-Host ''
    Write-Host 'Signature audit finished.' -ForegroundColor Green
    Write-Host "Repositories selected: $($reports.Summary.RepositoryCount)"
    Write-Host "Repositories attempted: $($reports.Summary.RepositoryAttemptedCount)"
    Write-Host "Repositories not attempted: $($reports.Summary.RepositoryNotAttemptedCount)"
    Write-Host "Branches:     $($reports.Summary.BranchCount)"
    Write-Host "Unique commits: $($reports.Summary.UniqueCommitCount)"
    Write-Host "Verified:     $($reports.Summary.VerifiedCount)" -ForegroundColor Green
    Write-Host "Unsigned:     $($reports.Summary.UnsignedCount)" -ForegroundColor Yellow
    Write-Host "Unknown key:  $($reports.Summary.UnknownKeyCount)"
    Write-Host "Invalid:      $($reports.Summary.InvalidCount)" -ForegroundColor Red
    Write-Host "Other unverified: $($reports.Summary.UnverifiedEmailCount + $reports.Summary.OtherUnverifiedCount)"
    Write-Host "Errors:       $($reports.Summary.ErrorCount)"
    Write-Host "Complete:     $($reports.Summary.Complete)"
    Write-Host ''
    Write-Host "Branches CSV: $($reports.BranchesCsv)"
    Write-Host "Commits CSV:  $($reports.CommitsCsv)"
    Write-Host "Commits JSON: $($reports.CommitsJson)"
    Write-Host "Errors CSV:   $($reports.ErrorsCsv)"
    Write-Host "Summary:      $($reports.SummaryPath)"

    if (-not $reports.Summary.Complete) {
        Write-Warn 'The audit is incomplete. Completed results were saved; review audit-errors.csv before treating the counts as final.'
        return 2
    }

    return 0
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

    $cancelHandlerReady = $false
    try {
        $cancelHandlerReady = [GcsV021ConsoleCancellation]::Register()
        if ($cancelHandlerReady) {
            Write-Host 'Console cancellation handler: Ready' -ForegroundColor Green
        }
        else {
            Write-Warn 'Console cancellation handler: Unavailable (no usable Windows console).'
        }
    }
    finally {
        if ($cancelHandlerReady) {
            [GcsV021ConsoleCancellation]::Unregister()
        }
    }

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
Git Commit Signer (GCS) - V0.2.1 preview

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\GCS.ps1 scan
  powershell -NoProfile -ExecutionPolicy Bypass -File .\GCS.ps1 audit
  powershell -NoProfile -ExecutionPolicy Bypass -File .\GCS.ps1 doctor

Commands:
  scan    Read-only inventory of repositories visible to the GitHub account.
  audit   Read-only scan of all accessible repository branches and commit signatures.
  doctor  Check Git, GitHub CLI, OpenSSH, authentication, and signing configuration.
  help    Show this help.

Options:
  -ExpectedLogin <login>       Abort if the authenticated GitHub account differs.
  -Repository <owner/name>      Audit only one visible repository (audit command).
  -RequestTimeoutSeconds <n>    Per-request timeout in seconds (default: 45; range: 5-600).
  -MaxRetries <n>               Retry transient request failures (default: 2; range: 0-5).
  -OutputDirectory <path>      Report directory (default: %LOCALAPPDATA%\GitCommitSigner\reports).

V0.1 scan and V0.2.1 audit are read-only. They do not rewrite commits, modify refs,
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
        'audit' {
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

            $cancelHandlerRegistered = $false
            try {
                $cancelHandlerRegistered = [GcsV021ConsoleCancellation]::Register()
                if (-not $cancelHandlerRegistered) {
                    Write-Warn 'Native Ctrl+C handling is unavailable in this console; graceful cancellation may not be possible.'
                }
                $auditExitCode = Invoke-Audit -Login $login -Directory $OutputDirectory -Repository $Repository
            }
            finally {
                if ($cancelHandlerRegistered) {
                    [GcsV021ConsoleCancellation]::Unregister()
                }
            }

            exit $auditExitCode
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
