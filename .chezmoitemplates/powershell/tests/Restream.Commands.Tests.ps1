$ErrorActionPreference = 'Stop'
$originalTemp = $env:TEMP
$testRoot = Join-Path $originalTemp ('restream-commands-' + [guid]::NewGuid())
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Start-TestPublisher([string]$name, [switch]$Unrelated) {
    $script = (Join-Path $testRoot 'RestreamPublisher.ps1').Replace("'", "''")
    $command = if ($Unrelated) { 'Start-Sleep 120' } else {
        "& '$script' 'https://example.com' 'best' 'config' 'test' 'rtsp://127.0.0.1:8554/$name' 'log' '0'"
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process ([Environment]::ProcessPath) -ArgumentList '-NoProfile', '-EncodedCommand', $encoded -WindowStyle Hidden -PassThru
    $processes.Add($process)
    Set-Content (Join-Path $testRoot "restream-$name.pid") $process.Id
    return $process
}
try {
    $null = New-Item $testRoot -ItemType Directory
    Copy-Item (Join-Path $PSScriptRoot '../Restream.ps1') $testRoot
    Set-Content (Join-Path $testRoot 'RestreamPublisher.ps1') 'Start-Sleep 120'
    $env:TEMP = $testRoot
    . (Join-Path $testRoot 'Restream.ps1')
    $one = Start-TestPublisher 'test-one'
    $two = Start-TestPublisher 'test-two'
    $unrelated = Start-TestPublisher 'test-unrelated' -Unrelated
    Set-Content (Join-Path $testRoot 'restream-invalid.pid') 'not a pid'
    $sessions = @(restream list)
    Assert ($sessions.Count -eq 4) 'list must return all tracked records'
    Assert (@($sessions | Where-Object Status -eq Running).Count -eq 2) 'only owned publishers should be running'
    restream stop test-one -WhatIf
    Assert (-not $one.HasExited) 'WhatIf killed a process'
    Assert (Test-Path (Join-Path $testRoot 'restream-test-one.pid')) 'WhatIf removed a record'
    restream stop test-one
    Assert ($one.WaitForExit(5000)) 'stop did not terminate publisher'
    Assert (-not $two.HasExited) 'stop affected another stream'
    restream stop test-unrelated
    Assert (-not $unrelated.HasExited) 'stale PID killed an unrelated process'
    restream stop -All -WhatIf
    Assert (-not $two.HasExited) 'stop -All -WhatIf killed a process'
    restream stop -All
    Assert ($two.WaitForExit(5000)) 'stop -All did not terminate publisher'
    Assert (@(restream list).Count -eq 0) 'stop -All left PID records'
    foreach ($arguments in @(@('stop'), @('start'), @('list','extra'), @('stop','../escape'))) {
        $failed = $false
        try { restream @arguments } catch { $failed = $true }
        Assert $failed "Invalid invocation accepted: $arguments"
    }
    # Fail immediately if either spelling of start launches anything under WhatIf.
    function Start-Process { throw 'Unexpected process launch' }
    restream start https://example.com -WhatIf
    restream https://example.com -WhatIf
    restream -Url https://example.com -WhatIf
    Write-Host 'PASS list, exact stop, stop -All, ownership, stale records, validation, and WhatIf'
} finally {
    $env:TEMP = $originalTemp
    foreach ($process in $processes) {
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
    # This is the single isolated directory created above, never a production temp path.
    if ($testRoot.StartsWith((Join-Path $originalTemp 'restream-commands-'))) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
