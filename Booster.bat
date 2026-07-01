@echo off
:: Lanzador de Booster - doble clic y listo (pide permisos de admin solo)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Booster.ps1"
