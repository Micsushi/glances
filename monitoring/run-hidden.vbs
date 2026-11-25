Option Explicit

Dim arguments, command, index, shell, exitCode
Set arguments = WScript.Arguments

If arguments.Count < 1 Then
    WScript.Quit 87
End If

command = QuoteArgument(arguments(0))
For index = 1 To arguments.Count - 1
    command = command & " " & QuoteArgument(arguments(index))
Next

Set shell = CreateObject("WScript.Shell")
Do
    exitCode = shell.Run(command, 0, True)
    If exitCode = 0 Then Exit Do
    On Error Resume Next
    shell.LogEvent 1, "Glances monitor exited with code " & exitCode & ". Restarting in 60 seconds."
    On Error GoTo 0
    WScript.Sleep 60000
Loop
WScript.Quit exitCode

Function QuoteArgument(value)
    QuoteArgument = Chr(34) & Replace(value, Chr(34), "\" & Chr(34)) & Chr(34)
End Function
