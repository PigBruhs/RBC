# 打包「最小可运行版本」到 release/BattleChess/
#
# 用法（在仓库根执行）：  powershell -ExecutionPolicy Bypass -File tools\make_release.ps1
#
# ⚠ 为什么是"文件夹 + 一键启动"而不是单个 exe：
#   本机**没有 Godot 导出模板**（%APPDATA%\Godot\export_templates 为空），
#   所以标准的 `--export-release` 单文件导出走不通。
#   改用：`godot.exe --path game` —— Godot 运行时本体**直接跑项目目录**，不需要模板。
#
# ⚠ 为什么 godot.exe 不在版本库里：
#   它 172 MB，**超过 GitHub 单文件 100 MB 上限**（已写进 .gitignore）。
#   本脚本每次打包时从 tools/godot/ 复制过去。

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$rel  = Join-Path $root 'release\BattleChess'
$godot = Join-Path $root 'tools\godot\Godot_v4.7.2-stable_win64.exe'

if (-not (Test-Path $godot)) { throw "找不到 Godot 运行时：$godot" }

Write-Host "[1/5] 重建 $rel"
if (Test-Path $rel) { Remove-Item $rel -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $rel 'game') -Force | Out-Null

Write-Host "[2/5] 复制运行时与项目"
Copy-Item $godot (Join-Path $rel 'godot.exe') -Force
Copy-Item (Join-Path $root 'game\project.godot') (Join-Path $rel 'game\project.godot') -Force
Copy-Item (Join-Path $root 'game\src') (Join-Path $rel 'game\src') -Recurse -Force

Write-Host "[3/5] 生成全局类缓存（⚠ 不做这一步，release 会满屏 'Identifier "Level" not declared'）"
# 新拷贝没有 .godot/ -> class_name 全局类没注册 -> 所有脚本解析失败。
# 先跑一次编辑器让它生成 global_script_class_cache.cfg。
& (Join-Path $rel 'godot.exe') --headless --path (Join-Path $rel 'game') --editor --quit-after 4000 | Out-Null

Write-Host "[4/5] 写启动器"
$bat = @'
@echo off
rem  战棋 BattleChess —— 一键启动（双击本文件，或双击同目录的「开始游戏.lnk」）
start "" "%~dp0godot.exe" --path "%~dp0game"
'@
Set-Content -Path (Join-Path $rel '开始游戏.bat') -Value $bat -Encoding ascii

$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $rel '开始游戏.lnk'))
$lnk.TargetPath = (Join-Path $rel 'godot.exe')
$lnk.Arguments = '--path "' + (Join-Path $rel 'game') + '"'
$lnk.WorkingDirectory = $rel
$lnk.IconLocation = (Join-Path $rel 'godot.exe') + ',0'
$lnk.Description = '战棋 BattleChess'
$lnk.Save()

Write-Host "[5/5] 清理编辑器缓存目录（保留 global_script_class_cache.cfg）"
Remove-Item (Join-Path $rel 'game\.godot\editor') -Recurse -Force -ErrorAction SilentlyContinue

$mb = (Get-ChildItem $rel -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("完成：$rel  （共 {0:N0} MB）" -f $mb)
Write-Host "双击「开始游戏.lnk」或「开始游戏.bat」即可游玩。"
