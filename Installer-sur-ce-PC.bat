@echo off
title Installation de Sylla Automobile
set "SCRIPT_DIR=%~dp0"

echo Installation du raccourci sur le Bureau...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$ws = New-Object -ComObject WScript.Shell;" ^
    "$desktop = [Environment]::GetFolderPath('Desktop');" ^
    "$s = $ws.CreateShortcut((Join-Path $desktop 'Sylla Automobile.lnk'));" ^
    "$s.TargetPath = '%SCRIPT_DIR%Lancer-Sylla-Automobile.bat';" ^
    "$s.WorkingDirectory = '%SCRIPT_DIR%';" ^
    "$s.IconLocation = '%SCRIPT_DIR%assets\img\sylla.ico,0';" ^
    "$s.WindowStyle = 7;" ^
    "$s.Description = 'Sylla Automobile - Gestion de stock et facturation';" ^
    "$s.Save()"

if %errorlevel%==0 (
    echo.
    echo Termine ! Le raccourci "Sylla Automobile" est maintenant sur le Bureau.
) else (
    echo.
    echo Une erreur est survenue. Le raccourci n'a peut-etre pas ete cree.
)
echo.
pause
