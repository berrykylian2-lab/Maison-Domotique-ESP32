@echo off
setlocal
cd /d "%~dp0"
echo Prototype Windows - Blender, Codex et MCP.
echo Fermez normalement Blender et Codex avant de poursuivre.
echo Sur un PC gere, obtenez d'abord l'autorisation du responsable.
echo Le script respecte les politiques PowerShell et les droits en place.
choice /C ON /N /M "Lancer l'installation ? [O/N] "
if errorlevel 2 exit /b 0
powershell.exe -NoProfile -File "%~dp0scripts\install-windows.ps1"
set "result=%errorlevel%"
echo.
echo Code de sortie : %result%
pause
exit /b %result%
