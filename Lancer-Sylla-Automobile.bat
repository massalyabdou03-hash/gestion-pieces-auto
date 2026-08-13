@echo off
rem Lance Sylla Automobile en mode "application" (fenetre autonome, sans
rem barre d'adresse ni onglets), quel que soit le navigateur installe.
rem L'appli est hebergee sur Netlify : les mises a jour sont donc automatiques,
rem il n'y a plus besoin de repasser ce dossier sur le PC de la boutique.

set "APP_URL=https://sylla-automobile.netlify.app/login.html"

set "CHROME1=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
set "CHROME2=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
set "CHROME3=%LocalAppData%\Google\Chrome\Application\chrome.exe"
set "EDGE1=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
set "EDGE2=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"

if exist "%CHROME1%" (
    start "" "%CHROME1%" --app="%APP_URL%"
    goto :eof
)
if exist "%CHROME2%" (
    start "" "%CHROME2%" --app="%APP_URL%"
    goto :eof
)
if exist "%CHROME3%" (
    start "" "%CHROME3%" --app="%APP_URL%"
    goto :eof
)
if exist "%EDGE1%" (
    start "" "%EDGE1%" --app="%APP_URL%"
    goto :eof
)
if exist "%EDGE2%" (
    start "" "%EDGE2%" --app="%APP_URL%"
    goto :eof
)

rem Aucun Chrome/Edge trouve : ouverture avec le navigateur par defaut
start "" "%APP_URL%"
