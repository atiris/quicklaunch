' Starts QuickLaunch with no console window at all.
' WScript.Shell.Run with windowStyle 0 is the only way to get a truly flash-free
' start; pwsh -WindowStyle Hidden still shows the console for a moment.
Option Explicit

Dim shell, fso, here, cmd
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
cmd  = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & _
       fso.BuildPath(here, "quicklaunch-run.ps1") & """"

' 0 = hidden window, False = do not wait
shell.Run cmd, 0, False
