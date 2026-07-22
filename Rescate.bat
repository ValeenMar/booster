@echo off
:: Booster Rescate - limpieza del robo de token de Discord
:: Doble clic y listo (pide permisos de admin solo)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Rescate.ps1"
