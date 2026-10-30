@echo off
rem Entry point for the Local AI launcher: local-ai.cmd [install|start|stop|status|update|uninstall|shortcuts].
rem RemoteSigned applies to this one invocation only, so the machine's execution policy is unchanged.
rem Pauses on a non-zero exit and after status, so the message stays readable in a window a shortcut
rem opened, except with -Json, which programs read. PowerShell binds any prefix of -Json, such as -j,
rem and --json too; -Json is the only switch that starts with j.
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0src\local-ai.ps1" %*
set "rc=%errorlevel%"
set "wait="
if not "%rc%"=="0" set "wait=1"
for %%a in (%*) do if /i "%%~a"=="status" set "wait=1"
rem Delayed expansion only from here, so the arguments PowerShell got keep any "!"; no label, which cmd.exe misreads in a file with LF line ends.
setlocal EnableDelayedExpansion
for %%a in (%*) do (
    set "arg=%%~a"
    if /i "!arg:~0,2!"=="-j" set "wait="
    if /i "!arg:~0,3!"=="--j" set "wait="
)
if defined wait pause
exit /b %rc%
