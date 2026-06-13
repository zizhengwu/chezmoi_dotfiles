#---------------------------------------------------------------------------------------------------------------
# https://gist.github.com/zett42/6a602120c253a86e4eebe35fcd53752f
# Defines keyboard shortcut Alt+E for the console to edit current input in VSCode
# (edit the line that starts with "code" to use another editor).
#
# This code is an extension of this StackOverflow answer:
# https://stackoverflow.com/a/71175083/7571258
#
# New features:
# - Saves/restores the current cursor position (if the text hasn't changed too much).
# - Passes the current cursor position to VSCode, so the editors cursor gets positioned as in the console.
# - While editing, show a console message to remind the user why this console is currently blocked
#   (remove the Write-Progress lines to disable this feature).
# - After editor has been closed, bring console window to foreground again (only on Windows and MacOS platform).
#
# When this code is put into the $Profile file, all new PowerShell console windows have Alt+E available.
#
# Special thanks to StackOverflow user mklement0 (https://stackoverflow.com/users/45375/mklement0) for
# providing many tipps to improve this code. Also see his alternative solution that uses
# built-in (but currently somewhat limited) way of PowerShell to edit console input in an external editor:
# https://stackoverflow.com/a/71181105/7571258
#---------------------------------------------------------------------------------------------------------------

function ConvertTo-LineAndChar {
    <#
    .SYNOPSIS
        Convert cursor position (offset) to line number and character index 
    #>    
    [CmdletBinding()]
    param(
        [Parameter()] [string[]] $lines, 
        [Parameter(Mandatory)] [int] $cursorPos     
    )

    if( $lines ) {
        $pos = $nextPos = 0

        for( $i = 0; $i -lt $lines.Count; $i++ ){ 

            $nextPos = $pos + $lines[ $i ].Length + 1
            
            if( $nextPos -gt $cursorPos ) {
                return [PSCustomObject]@{ line = $i; char = $cursorPos - $pos }
            }
            
            $pos = $nextPos
        }
    }

    [PSCustomObject]@{ line = 0; char = 0 }  # default output
}

#---------------------------------------------------------------------------------------

function ConvertTo-CursorPos {
    <#
    .SYNOPSIS
        Convert line and char index to cursor position (offset) 
    #>
    [CmdletBinding()]
    param (
        [Parameter()] [string[]] $lines, 
        [Parameter(Mandatory)] [int] $nLine,     
        [Parameter(Mandatory)] [int] $nChar    
    )

    if( -not $lines ) {
        return 0
    }

    $nLine = [Math]::Min( $nLine, $lines.Count - 1 )
    $pos = 0

    for( $i = 0; $i -lt $nLine; $i++ ){     
        $pos += $lines[ $i ].Length + 1
    }

    # Output
    $pos + [Math]::Min( $nChar, $lines[ $nLine ].Length )
}

#---------------------------------------------------------------------------------------
# Define keyboard shortcut Ctrl+x,Ctrl+e to edit the current console line in VSCode

Set-PSReadLineKeyHandler -Chord 'Ctrl+x,Ctrl+e','Ctrl+x,e' -ScriptBlock {

    $currentInput = $null
    [int] $cursorPos = 0

    # Copy current command-line input and get cursor position
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref] $currentInput, [ref] $cursorPos)

    # Save current command-line to temp file
    $tempFileName = "ps_$PID.ps1"
    $tempFilePath = Join-Path ([IO.Path]::GetTempPath()) $tempFileName
    Set-Content $tempFilePath -Value $currentInput -Encoding utf8

    # Convert cursor position to line and char index 
    $currentInputLines = @($currentInput -split '\r?\n')
    $goto = ConvertTo-LineAndChar -lines $currentInputLines -cursorPos $cursorPos

    # Show a message to remind the user why this console is currently blocked
    Write-Progress -Activity 'External editing in progress' -Status "Close VSCode ($tempFileName) to continue working in this console" -PercentComplete -1

    # Edit the command using VSCode (passing the cursor position to the editor) 
    code --new-window --wait --goto "${tempFilePath}:$($goto.line + 1):$($goto.char + 1)"

    # Remove the message
    Write-Progress -Activity 'External editing in progress' -Completed

    # Get the edited input as individual lines
    $editedInputLines = Get-Content -LiteralPath $tempFilePath -Encoding utf8 

    # Cleanup
    Remove-Item $tempFilePath

    # The console always uses LF character as line separator, regardless of platform. 
    $editedInput = ($editedInputLines -join "`n").Trim()

    # Replace current console line with the content of the temp file
    [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $currentInput.Length, $editedInput)

    # Try to restore cursor position (if text hasn't changed too much)
    $cursorPos = ConvertTo-CursorPos -lines $editedInputLines -nLine $goto.line -nChar $goto.char 
    [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition( $cursorPos )

    # Bring console window to foreground again
    if( $env:OS -eq 'Windows_NT' ) {   
        (New-Object -ComObject WScript.Shell).AppActivate( $PID ) 
    } 
    elseif( $IsMacOS ) {   
        $terminalAppName = $env:TERM_PROGRAM  
        if( $terminalAppName -eq 'Apple_Terminal' ) { 
            $terminalAppName = 'Terminal.app' 
        }
        $PSNativeCommandArgumentPassing = 'Legacy'   
        osascript -e "tell application \""$terminalAppName\"" to activate" 2>$null 
    }

    # Uncomment this to automatically press "Enter" key in the console after editing.
    #[Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
}