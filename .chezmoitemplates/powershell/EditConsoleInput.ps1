#---------------------------------------------------------------------------------------------------------------
# https://gist.github.com/zett42/6a602120c253a86e4eebe35fcd53752f
# Defines keyboard shortcut for the console to edit current input in VSCode
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

$SublimeCommand = "subl"

function ConvertTo-LineAndChar {
    <#
    .SYNOPSIS
        Convert cursor position offset to line number and character index.
        This is only used to open Sublime at the current console cursor position.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string[]] $Lines,
        [Parameter(Mandatory)] [int] $CursorPos
    )

    if ($Lines) {
        $pos = 0

        for ($i = 0; $i -lt $Lines.Count; $i++) {
            $nextPos = $pos + $Lines[$i].Length + 1

            if ($nextPos -gt $CursorPos) {
                return [PSCustomObject]@{
                    line = $i
                    char = $CursorPos - $pos
                }
            }

            $pos = $nextPos
        }
    }

    [PSCustomObject]@{
        line = 0
        char = 0
    }
}

function Split-LF {
    param(
        [Parameter()] [AllowNull()] [string] $Text
    )

    if ($null -eq $Text) {
        return @("")
    }

    @($Text -split "`n")
}

Set-PSReadLineKeyHandler -Chord 'Ctrl+x,Ctrl+e','Ctrl+x,e' -ScriptBlock {
    $currentInput = $null
    [int] $cursorPos = 0

    # Copy current command-line input and get cursor position.
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState(
        [ref] $currentInput,
        [ref] $cursorPos
    )

    # Save current command-line input to a temp file.
    $tempFileName = "ps_$PID.ps1"
    $tempFilePath = Join-Path ([IO.Path]::GetTempPath()) $tempFileName

    try {
        # Write raw UTF-8 without adding an extra newline.
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tempFilePath, $currentInput, $utf8NoBom)

        # Convert original console cursor position to line/column for Sublime.
        # This is only used when opening Sublime.
        $currentInputLines = Split-LF $currentInput
        $goto = ConvertTo-LineAndChar -Lines $currentInputLines -CursorPos $cursorPos

        Write-Progress `
            -Activity 'External editing in progress' `
            -Status "Save and close Sublime Text file ($tempFileName) to continue working in this console" `
            -PercentComplete -1

        # Sublime uses file:line:column syntax.
        # PSReadLine uses zero-based line/char internally; Sublime uses one-based line/column.
        $sublimeTarget = "${tempFilePath}:$($goto.line + 1):$($goto.char + 1)"

        # Open in a new Sublime window and wait until the file is closed.
        & $SublimeCommand -n -w -- $sublimeTarget

        Write-Progress -Activity 'External editing in progress' -Completed

        # Read raw text back exactly.
        $editedInput = [System.IO.File]::ReadAllText(
            $tempFilePath,
            [System.Text.Encoding]::UTF8
        )

        # Normalize line endings for PSReadLine.
        $editedInput = $editedInput -replace "`r`n", "`n" -replace "`r", "`n"

        # Do NOT use .Trim(); it can remove meaningful whitespace.
        # Remove only final newline characters that editors may add automatically.
        $editedInput = $editedInput.TrimEnd([char[]]@("`r", "`n"))

        # Replace current console input with edited content.
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace(
            0,
            $currentInput.Length,
            $editedInput
        )

        # Important:
        # Do NOT call SetCursorPosition here.
        # Let PSReadLine handle the cursor after Replace().
    }
    finally {
        Write-Progress -Activity 'External editing in progress' -Completed
        Remove-Item -LiteralPath $tempFilePath -ErrorAction SilentlyContinue
    }

    # Bring console window to foreground again.
    if ($env:OS -eq 'Windows_NT') {
        try {
            (New-Object -ComObject WScript.Shell).AppActivate($PID) | Out-Null
        } catch {
            # Ignore focus errors.
        }
    }
    elseif ($IsMacOS) {
        $terminalAppName = $env:TERM_PROGRAM

        if ($terminalAppName -eq 'Apple_Terminal') {
            $terminalAppName = 'Terminal.app'
        }

        $oldArgumentPassing = $PSNativeCommandArgumentPassing
        try {
            $PSNativeCommandArgumentPassing = 'Legacy'
            osascript -e "tell application `"$terminalAppName`" to activate" 2>$null
        } finally {
            $PSNativeCommandArgumentPassing = $oldArgumentPassing
        }
    }

    # Uncomment this to automatically press Enter after editing.
    # [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
}