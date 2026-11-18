@echo off
REM FakeGPS (Windows) — 需要系統管理員權限建立 tunnel；此批次檔會自動提權重啟
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo 需要系統管理員權限，正在提權...
  powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

REM 優先用 py launcher（python.org 安裝會附帶），否則退回 python。
REM 注意：Microsoft Store 的 python.exe 是空殼，不會真的執行，故優先 py。
set "PY=py"
where py >nul 2>&1 || set "PY=python"
%PY% --version >nul 2>&1 || (echo [錯誤] 找不到可用的 Python，請從 python.org 安裝 Python 3.11+（勾選 Add to PATH） ^& pause ^& exit /b)

echo 安裝 / 更新 pymobiledevice3 ...
%PY% -m pip install --quiet -r "%~dp0requirements.txt"
echo 啟動 FakeGPS ...
%PY% "%~dp0app.py"
pause
