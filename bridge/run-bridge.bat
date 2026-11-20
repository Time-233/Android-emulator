@echo off
chcp 65001 >nul
title droidbridge - 安卓运行时桥
cd /d "%~dp0"

echo ============================================
echo   droidbridge: 把安卓设备变成 iPhone 的运行时
echo ============================================
echo.

where adb >nul 2>nul
if errorlevel 1 (
  echo [!] 没找到 adb。请先装 Android platform-tools 并加进 PATH，
  echo     或者把 --adb 指向 adb.exe 的完整路径。
  echo     只想先验证链路的话，用 mock 模式： %~nx0 mock
  echo.
)

py -3 --version >nul 2>nul
if errorlevel 1 (
  echo [!] 没找到 python3，请先安装 Python 3.8+ 
  pause
  exit /b 1
)

if /i "%~1"=="mock" (
  echo [i] mock 模式：只发假画面，用来验证 iPhone 能不能连上
  py -3 droidbridge.py --mock --fps 4
) else (
  py -3 droidbridge.py %*
)

echo.
echo 服务已退出。
pause
