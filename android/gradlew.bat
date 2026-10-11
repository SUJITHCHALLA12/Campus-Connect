@echo off
rem Self-bootstrapping Gradle launcher for Campus Connect (Windows).
rem Downloads Gradle 8.14 once into %USERPROFILE%\.gradle-bootstrap and runs it.
setlocal
set GRADLE_VERSION=8.14
set BOOT_DIR=%USERPROFILE%\.gradle-bootstrap
set DIST_DIR=%BOOT_DIR%\gradle-%GRADLE_VERSION%

if not exist "%DIST_DIR%\bin\gradle.bat" (
  echo Downloading Gradle %GRADLE_VERSION% (one-time)...
  if not exist "%BOOT_DIR%" mkdir "%BOOT_DIR%"
  set TMP_ZIP=%BOOT_DIR%\gradle-%GRADLE_VERSION%-bin.zip
  powershell -NoProfile -Command "Invoke-WebRequest -Uri 'https://services.gradle.org/distributions/gradle-%GRADLE_VERSION%-bin.zip' -OutFile '%TMP_ZIP%'"
  powershell -NoProfile -Command "Expand-Archive -Path '%TMP_ZIP%' -DestinationPath '%BOOT_DIR%' -Force"
  del "%TMP_ZIP%"
)

"%DIST_DIR%\bin\gradle.bat" -p "%~dp0" %*
