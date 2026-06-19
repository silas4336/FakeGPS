@echo off
REM FakeGPS (Windows) — 需要系統管理員權限建立 tunnel；此批次檔會自動提權重啟
net session >/dev/null 2>&1
if %errorlevel% neq 0 (
  echo 需要系統管理員權限，正在提權...
  powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
where python >/dev/null 2>&1 || (echo [錯誤] 找不到 Python，請先從 python.org 安裝 Python 3.11+ & pause & exit /b)
echo 安裝 / 更新 pymobiledevice3 ...
python -m pip install --quiet --upgrade pymobiledevice3
echo 啟動 FakeGPS ...
python "%~dp0app.py"
pause
