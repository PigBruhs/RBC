# ══════════════════════════════════════════════════════════════════════════════
# 包装层门禁的自检（把 check_wrappers.gd 的四条红线固化成可复跑的回归网）
#
# 为什么要它：那四条红线当初是靠团队成员各自的**临时探针**验的，探针没进仓库 ——
# 下次谁改 check_wrappers.gd 的逻辑，就没有东西能证明它还有牙。
# 这里用**合成的模块/宿主文本**（不是项目真实代码）逐个构造违规，断言门禁必须 exit=1；
# 再断言一个合法写法 exit=0（防"拦正确代码"的假阳性）。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path game \
#       --script res://tests/check_wrappers_selftest.gd --quit-after 60000
# 退出码 0 = 门禁四条红线都有牙且不误杀；1 = 有场景不符预期（会列出是哪条）。
#
# 注意：本文件会写临时 fixture 到 res://tests/_wrapfix/，跑完自动删除。
# ══════════════════════════════════════════════════════════════════════════════
extends SceneTree

const GATE := "res://tests/check_wrappers.gd"
const FIX_DIR := "res://tests/_wrapfix"
const EXE_HINT := "tools\\godot\\Godot_v4.7.2-stable_win64_console.exe"


func _initialize() -> void:
	var fails: Array[String] = []
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIX_DIR))
	var cases: Array = _cases()
	var n := 0

	for c in cases:
		var mod_p := "%s/mod_%s.gd" % [FIX_DIR, c["id"]]
		var host_p := "%s/host_%s.gd" % [FIX_DIR, c["id"]]
		_write(mod_p, String(c["mod"]))
		_write(host_p, String(c["host"]))
		var got := _run_gate(mod_p, host_p, String(c.get("rename", "")))
		var want := int(c["expect"])
		n += 1
		var ok := got == want
		if ok:
			print("  PASS  %-34s 门禁 exit=%d（与预期一致）" % [c["name"], got])
		else:
			print("  FAIL  %-34s 门禁 exit=%d，预期 %d" % [c["name"], got, want])
			fails.append("%s：门禁 exit=%d，预期 %d" % [c["name"], got, want])

	# ⚠️ 这里**没有**"覆盖漂移"场景，原因是环境限制而非偷懒：
	#    覆盖自检依赖 check_wrappers.gd 里 `FORWARDING_MEMBERS` ↔ `MODULES` 的对齐。
	#    要构造漂移，得临时给 MODULES 加一条**不存在的模块**再跑门禁；而门禁读模块用 `res://`，
	#    引擎启动后新建的文件在**本次运行**里对 `res://` 不可见（实测 FileAccess.file_exists
	#    返回 false，必须重扫/重启才看得到）。所以这个场景无法在自检里可靠复现。
	#    替代验证（人工，已做过一次）：临时注释掉 MODULES 里 projectile_field 那条 →
	#    门禁应 exit 1 并报 `✗ 覆盖漂移：`field`（projectile_field.gd）未登记在 MODULES`。

	print("\n── 包装层门禁自检 ──")
	print("跑了 %d 个场景（5 条红线 + 1 个合法形态）" % n)
	if fails.is_empty():
		print("✅ 五条红线都有牙，且不拦合法写法")
		_cleanup(false)
		quit(0)
	else:
		print("❌ 有 %d 个场景不符预期：" % fails.size())
		for f in fails:
			print("   - ", f)
		_cleanup(true)
		quit(1)


## 四个违规场景（对应四条红线）+ 一个合法场景（防假阳性）
func _cases() -> Array:
	# 合成模块：一个同步函数、一个【协程 + 有返回值】、一个【协程 + void】
	# ⚠️ 刻意**不让目标函数排第一**：曾经有过"解析只对文件首个函数生效"的缺陷，
	#    探针若把目标放在首位就区分不出"已修好"与"没踩到"。
	var mod := """extends RefCounted

func dummy_first() -> void:
	pass


func sync_bool() -> bool:
	return true


func coro_bool() -> bool:
	await Engine.get_main_loop().process_frame
	return true


func coro_void() -> void:
	await Engine.get_main_loop().process_frame
"""
	# ① 同步模块 + await 包装（把同步变协程、时序漂移）
	var host_r1 := """extends Node

func sync_bool() -> bool:
	await mod.sync_bool()
"""
	# ② 模块协程 / 包装同步（漏 await）
	var host_r2 := """extends Node

func coro_bool() -> bool:
	return mod.coro_bool()
"""
	# ③ 签名收窄（-> bool 改成 -> void）+ 裸 await
	var host_r3 := """extends Node

func coro_bool() -> void:
	await mod.coro_bool()
"""
	# ④ 签名一致 + 裸 await（丢返回值）
	var host_r4 := """extends Node

func coro_bool() -> bool:
	await mod.coro_bool()
	return true
"""
	# ⑤ 合法：捕获再返回（等价于 return await）—— 曾经被误杀
	var host_ok := """extends Node

func coro_bool() -> bool:
	var r: bool = await mod.coro_bool()
	return r


func coro_void() -> void:
	await mod.coro_void()
"""
	# ⑥ 捕获了却**不**交回（`return true`）—— 从"签名一致 ⇒ 捕获不会掩盖丢返回值"的论证里反推出来的缺口
	var host_r5 := """extends Node

func coro_bool() -> bool:
	var r: bool = await mod.coro_bool()
	return true
"""
	return [
		{"id": "r1", "name": "① 同步模块 + await 包装", "mod": mod, "host": host_r1, "expect": 1},
		{"id": "r2", "name": "② 模块协程 / 包装同步", "mod": mod, "host": host_r2, "expect": 1},
		{"id": "r3", "name": "③ 签名收窄 + 裸 await", "mod": mod, "host": host_r3, "expect": 1},
		{"id": "r4", "name": "④ 签名一致 + 裸 await", "mod": mod, "host": host_r4, "expect": 1},
		{"id": "r5", "name": "⑤ 捕获了却不交回", "mod": mod, "host": host_r5, "expect": 1},
		{"id": "ok", "name": "⑥ 合法：捕获再返回（不误杀）", "mod": mod, "host": host_ok, "expect": 0},
	]


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("写不了 %s" % path)
		return
	f.store_string(text)
	f.close()


## 起一个子进程跑门禁，返回它的退出码。
## 参数放在 `--` 之后，门禁用 OS.get_cmdline_user_args() 读。
##
## ⚠️ 两个坑（都踩过）：
##   1) `--path` **必须是绝对路径**：子进程的工作目录不一定是仓库根，
##      传相对的 "game" 会让 Godot 直接 `Invalid project path specified` 退出（exit 1）——
##      于是**所有**场景都"符合预期"，自检变成永远绿的假测试。
##   2) 必须**只把退出码当结论**，并且要求子进程真的跑起来了：
##      下面会检查输出里没有 `Invalid project path` 之类的启动失败。
func _run_gate(mod_p: String, host_p: String, rename: String) -> int:
	var proj := ProjectSettings.globalize_path("res://")
	var args := PackedStringArray([
		"--headless", "--path", proj, "--script", GATE, "--quit-after", "3000",
		"--", "--mod=" + mod_p, "--host=" + host_p,
	])
	if rename != "":
		args.append("--rename=" + rename)
	var out: Array = []
	# 子进程的中文输出会被按本地代码页解码成乱码（Windows），导致下面的文本判据失效。
	# 用 PYTHONIOENCODING 那招不行（这里是 Godot 不是 Python），改为只依赖**ASCII 判据** + 退出码：
	# 见下面的 started 判定。
	var code := OS.execute(OS.get_executable_path(), args, out, true)
	var text := ""
	for blk in out:
		text += String(blk)
	# 判据只用 ASCII，避免中文乱码影响判断：
	#   · 启动失败（路径不对/脚本加载失败）→ Godot 打 `Invalid project path` / `Failed to load script`
	#   · 门禁真的跑了 → 一定有模块小节标题 `── ` 与汇总里的 `=====`/计数行里的 ASCII 片段
	var started := not text.contains("Invalid project path") \
		and not text.contains("Failed to load script") \
		and text.contains("Godot Engine v")
	if not started:
		print("        │ [自检错误] 门禁进程没跑起来/脚本加载失败，exit=%d" % code)
		for line in text.split("\n"):
			var t := String(line).strip_edges()
			if t != "" and not t.begins_with("Godot Engine v"):
				print("        │   ", t)
		return -999
	# 门禁自己的失败明细在这里**不再重复打印**：子进程的中文会被按本地代码页解码成乱码，
	# 打出来只是噪声。要看明细就直接单跑门禁：
	#   godot --headless --path game --script res://tests/check_wrappers.gd
	return code


func _cleanup(keep: bool = false) -> void:
	if keep:
		print("（自检失败：fixture 保留在 %s 供排查）" % FIX_DIR)
		return
	var d := DirAccess.open(FIX_DIR)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIX_DIR))
