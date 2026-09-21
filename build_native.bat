@echo off
echo ========================================================
echo Building NetStudio Rust Core Dynamic Library (DLL)...
echo ========================================================

cd /d "%~dp0\native_engine"
cargo build --release

if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Cargo build failed!
    exit /b %ERRORLEVEL%
)

echo.
echo [SUCCESS] Rust core compiled successfully.
echo Copying netstudio_engine.dll to project directories...

if exist "target\release\netstudio_engine.dll" (
    copy /y "target\release\netstudio_engine.dll" "%~dp0\"
    if exist "%~dp0\build\windows\x64\runner\Debug" (
        copy /y "target\release\netstudio_engine.dll" "%~dp0\build\windows\x64\runner\Debug\"
    )
    if exist "%~dp0\build\windows\x64\runner\Release" (
        copy /y "target\release\netstudio_engine.dll" "%~dp0\build\windows\x64\runner\Release\"
    )
    echo Copied netstudio_engine.dll successfully.
) else (
    echo [WARN] target\release\netstudio_engine.dll not found.
)

echo ========================================================
echo Done. You can now run 'flutter run -d windows'
echo ========================================================
