oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH/probua.minimal.omp.json" | Invoke-Expression
Import-Module PSReadLine
Set-PSReadLineOption -EditMode Emacs
Set-PSReadLineKeyHandler -Key Ctrl+Shift+v -Function Paste
Set-PSReadLineKeyHandler -Key Ctrl+w -Function BackwardKillWord
Set-PSReadlineKeyHandler -Key Tab -Function MenuComplete
atuin init powershell --disable-up-arrow | Out-String | Invoke-Expression
# zsh-ish: HIST_FIND_NO_DUPS
Set-PSReadLineOption -HistoryNoDuplicates
# zsh-ish: HIST_IGNORE_DUPS
Set-PSReadLineOption -AddToHistoryHandler {
    param([string] $line)

    if ([string]::IsNullOrWhiteSpace($line)) {
        return 'SkipAdding'
    }

    $items = [Microsoft.PowerShell.PSConsoleReadLine]::GetHistoryItems()
    $last = if ($items.Count) { $items[-1].CommandLine } else { $null }

    if ($line -eq $last) {
        return 'SkipAdding'
    }

    return 'MemoryAndFile'
}
Import-Module -Name Terminal-Icons
Set-PSReadLineOption -Colors @{
   "Default"   = [ConsoleColor]::Black
   "Parameter" = [ConsoleColor]::Black
   "Type"      = [ConsoleColor]::DarkBlue
   "Number"    = [ConsoleColor]::Magenta
   "String"    = [ConsoleColor]::Magenta
   "Comment"   = [ConsoleColor]::Yellow
   "Variable"  = [ConsoleColor]::Green
   "Keyword"   = [ConsoleColor]::Blue
   "Operator"  = [ConsoleColor]::Blue
   "Command"   = [ConsoleColor]::Blue
   "Member"    = [ConsoleColor]::Blue
   "Error"     = [ConsoleColor]::Red
}
# Import the Chocolatey Profile that contains the necessary code to enable
# tab-completions to function for `choco`.
# Be aware that if you are missing these lines from your profile, tab completion
# for `choco` will not function.
# See https://ch0.co/tab-completion for details.
$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}

$profileDir = Split-Path -Parent $PSCommandPath
. (Join-Path $profileDir 'EditConsoleInput.ps1')
Invoke-Expression (& { (zoxide init powershell | Out-String) })
