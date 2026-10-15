$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot '../RestreamLogTee.cs'), `
    (Join-Path $PSScriptRoot '../RestreamBuffer.cs'), `
    (Join-Path $PSScriptRoot 'RestreamBuffer.Tests.cs')
$null = [RestreamBufferTests]::RunAsync([Environment]::ProcessPath).GetAwaiter().GetResult()
