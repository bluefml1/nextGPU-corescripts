' Hidden launcher: prefer WinExe NextGPU.Launcher --play-elevated (no powershell.exe console).
Option Explicit

Dim sh, fso, launcher, cmd, i, a, wait
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

launcher = sh.ExpandEnvironmentStrings("%ProgramFiles%\NextGPU\Launcher\NextGPU.Launcher.exe")
If Not fso.FileExists(launcher) Then
  WScript.Quit 2
End If

Function Quote(s)
  Quote = """" & Replace(CStr(s), """", """""") & """"
End Function

cmd = Quote(launcher) & " --play-elevated"
wait = False
For i = 0 To WScript.Arguments.Count - 1
  a = WScript.Arguments(i)
  If LCase(a) = "-wait" Or LCase(a) = "--wait" Then
    wait = True
    cmd = cmd & " --wait"
  ElseIf LCase(a) = "-exe" Then
    cmd = cmd & " --exe"
  ElseIf LCase(a) = "-workingdir" Then
    cmd = cmd & " --cwd"
  ElseIf LCase(a) = "-args" Then
    cmd = cmd & " --args"
  Else
    cmd = cmd & " " & Quote(a)
  End If
Next

sh.Run cmd, 0, wait
WScript.Quit 0
