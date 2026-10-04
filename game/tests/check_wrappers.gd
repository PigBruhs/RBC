# ══════════════════════════════════════════════════════════════════════════════
# 包装层一致性检查（重构期的常驻门禁）
#
# 背景：把 battle_scene.gd 拆成模块之后，宿主里会留下一批**同名薄包装**（转发到模块）。
# 这批包装有一个只有运行时才会暴露的坑（第 97 轮第二期两边各踩过一次）：
#
#   包装的"协程性"必须与被包装的模块函数**逐字一致** ——
#     · 模块函数含 await（协程）＋有返回值 ->  包装写 `return await mod.fn(...)`
#     · 模块函数含 await（协程）＋`-> void` -> 包装写 `await mod.fn(...)`
#       （void 里写 `return await` 会被 GDScript 拒绝）
#     · 模块函数是同步的                  ->  包装写 `return mod.fn(...)` / `mod.fn(...)`
#       **绝对不许加 await**：加了会把"调用即完成"变成"下一帧才完成"，
#       而测试往往仍然是绿的（只是时序漂了）—— 这个镜像版本比漏 await 更隐蔽。
#
# 判定依据是 Godot 官方的协程契约：
#   · 调用**哪个函数会返回 GDScriptFunctionState**，取决于**调用点有没有写 await** ——
#     一个函数只要体内某处 `await` 了别的协程，它自己就是协程；
#     但如果它只是**调用**一个协程而不 await（例如 basic_burst 里的 `volley_bullets(...)`），
#     它自己仍然是**同步**函数、立刻返回。所以扫描时必须区分"体内出现 await"与"调用点是 await"。
#   本脚本的做法：先按缩进块找出每个函数体里的**真正 await 语句**（行首 await / `= await` / `await` 作为独立语句），
#   再据此判断这个函数是不是协程。纯文本扫描，不需要跑场景。
#
# 运行：
#   Godot_v4.7.2-stable_win64_console.exe --headless --path game \
#       --script res://tests/check_wrappers.gd --quit-after 3000
# 退出码 0 = 全部合规；1 = 有包装与模块不一致（会逐条列出来）。
#
# 新增模块时：在下面的 MODULES 里加一行（模块路径 + 宿主路径）即可，不用改逻辑。
# ══════════════════════════════════════════════════════════════════════════════
extends SceneTree

## 模块 -> 宿主。宿主里的同名薄包装必须与模块函数的协程性一致。
## `rename` 用来处理"模块函数名与宿主包装名不一致"的情况：
##   哨兵模块里的方法叫 tick / fire / lock，而宿主为了保住测试的 `_s._tick_sentry_queue()`
##   等调用，包装仍叫 `_tick_sentry_queue` / `_sentry_fire` / `_sentry_lock`，所以显式列出来。
##   （默认规则：模块无下划线 -> 宿主加下划线；模块带下划线 -> 宿主去掉下划线。）
## 模块 -> 宿主。宿主里的同名薄包装必须与模块函数的协程性一致。
## `rename` 用来处理"模块函数名与宿主包装名不一致"的情况：
##   哨兵模块里的方法叫 tick / fire / lock，而宿主为了保住测试的 `_s._tick_sentry_queue()`
##   等调用，包装仍叫 `_tick_sentry_queue` / `_sentry_fire` / `_sentry_lock`，所以显式列出来。
##   （默认规则：模块无下划线 -> 宿主加下划线；模块带下划线 -> 宿主去掉下划线。）
## `scan_only` 只检查列出的这些模块函数（其余跳过）：模块里既有"被包装的函数"，
##   也有大量**数据访问/工厂**（`items` 字段、`kind_cn()`、`build_grenade_model()`…），
##   后者本来就不需要包装，不筛掉会刷一堆无意义的"未发现转发"。
const MODULES := [
	{"mod": "res://src/view/projectile_sink.gd", "host": "res://src/view/battle_scene.gd"},
	{"mod": "res://src/view/basic_attack.gd", "host": "res://src/view/battle_scene.gd"},
	{"mod": "res://src/view/view_fx.gd", "host": "res://src/view/battle_scene.gd"},
	{"mod": "res://src/view/skill_runner.gd", "host": "res://src/view/battle_scene.gd"},
	# 哨兵的三个方法在宿主里的包装名与模块不同（宿主为了保住测试的
	# `_s._tick_sentry_queue()` 等调用而改了名），所以显式列出。
	# ⚠️ 第 97 轮 P0 清账期之后，宿主里的同名薄包装**已删掉 45 个**，
	# 只剩 5 个"跨模块回调"（别的模块通过 `_st._xxx` 调它，删了会断）。
	# 所以这个数组现在的意义变了：它守的是**跨模块事实接口**，不再是"测试门面"。
	{
		"mod": "res://src/view/sentry_runner.gd",
		"host": "res://src/view/battle_scene.gd",
		"rename": {"tick": "_tick_sentry_queue", "fire": "_sentry_fire", "lock": "_sentry_lock"},
	},
	# ── 下面两个**不是**本轮拆出来的模块，但它们**已经有薄包装**在转发 ──
	# 加进来是因为门禁真正该管的不是"谁被拆出来了"，而是"谁的包装在转发"：
	# 只要宿主里有 `return field.xxx(...)` / `ui.xxx(...)` 这种单语句转发，
	# 那个包装的协程性/签名就该被检查 —— 否则它属于"检查实际上没在检查"。
	# 今天这些包装全是同步的、不会产生失败（从"没人看"变成"被看"）；
	# 哪天 BattleUI 的某个 refresh 加了动画 await，这里就会红。
	{
		"mod": "res://src/view/projectile_field.gd",
		"host": "res://src/view/battle_scene.gd",
		"scan_only": ["clear", "live_count", "collision"],
	},
	{
		"mod": "res://src/view/battle_ui.gd",
		"host": "res://src/view/battle_scene.gd",
		"scan_only": ["refresh_detail", "refresh_upgrades"],
	},
]

## 这些函数名不参与检查（例如宿主自己也有实现、不是纯转发的）
const SKIP := ["_init", "_ready", "_process"]

## 提示（不影响结论）与失败（拦下来）的分界：
##   fails  —— 包装与模块**不一致**：协程性不符、协程包装缺 await、**丢了返回值**、覆盖漂移。
##             这几类都是"语义已经变了但测试还是绿的"，必须拦。
##   notes  —— 有歧义、不该误杀的：包装写了 `return await` 但模块没标返回类型。

## ⚠️ 曾经这里有一张 `MODULE_FIELD_NAMES`（4 项）与一个 `_scan_module_fields()`，
## 用来"从宿主字段声明推导覆盖面"。**两者都已删除**，原因：
##   · 它推导出的表已经过时（少了 `field`/`ui`），而真正生效的是 `FORWARDING_MEMBERS`；
##   · 留一张"没人调用、且已过时"的表，下一个人改它以为有用、实际静默无效 ——
##     本仓已经被"同一判定写两份 → 漂移"咬过三次（`_cc`/`Ordnance._cell_center`、
##     两处 needle、这张表）。所以就地删掉，别再复活它。

## PascalCase -> snake_case（`ProjectileSink` -> `projectile_sink`）
static func _to_snake(s: String) -> String:
	var out := ""
	for i in range(s.length()):
		var ch := s[i]
		if ch == ch.to_upper() and ch != ch.to_lower() and i > 0:
			out += "_"
		out += ch.to_lower()
	return out


## 覆盖自检：声明式，而不是"猜"。
##
## 为什么要有这条：**门禁最容易被绕过的方式不是被改坏，而是被漏掉** ——
## 再拆一个新模块时忘了往 MODULES 加一行，门禁会照常打印"检查了 N 个包装 ✅ 全合规"，
## 新模块完全不设防且毫无提示。
##
## ⚠️ 试过"从宿主代码自动推导覆盖面"，**两条路都不成立**，别再走：
##   · 按 `.new(self)` 构造形态：宿主有两种注入风格（`.new(self)` 与 `.new()` + `setup()`），
##     只认前者会漏掉后者（`ProjectileField` / `BattleUI` / `SentryRange` 就是这么漏的）。
##   · 按"单语句转发"（`^return x.f(...)$` 之类）：**假阳性爆炸** —— `parts.append(...)`、
##     `x.foo()` 这类局部变量方法调用长得一模一样，实测在 battle_scene.gd 上误报 40 个。
## 所以改成把"宿主里哪些成员是模块"显式写下来（下面那张表），
## 再断言"表里的每个成员都在 MODULES 里有对应条目"。
## 代价：加新模块要动两处（表 + MODULES）——**这正是想要的**：加模块时必须显式过一遍覆盖面。
##
## 表的值是"该成员由哪个模块文件实现"。只列**有薄包装转发**的成员；
## 宿主自己的 `gm` / `queue` / `_camera` 这些不是本文件拆出去的模块，不在表里。
const FORWARDING_MEMBERS := {
	"sentry": "res://src/view/sentry_runner.gd",
	"fx": "res://src/view/view_fx.gd",
	"sink": "res://src/view/projectile_sink.gd",
	"attack": "res://src/view/basic_attack.gd",
	"skills_mod": "res://src/view/skill_runner.gd",
	"field": "res://src/view/projectile_field.gd",
	"ui": "res://src/view/battle_ui.gd",
}

## 明确豁免：这些成员是被注入宿主的协作者，但**没有薄包装在转发**，
## 所以没有"包装协程性"可谈，不需要进 MODULES。
## 写下来是为了让 `_injection_note()` 的提示保持干净 —— 有意的豁免 != 漏登记。
const FORWARDING_EXEMPT := {
	"sentry_range": "SentryRange：宿主直接调它的 sync()，没有同名薄包装",
}


func _check_coverage(modules: Array, fails: Array[String], host_override: String) -> String:
	if host_override != "":
		return "（命令行覆盖模式：跳过覆盖自检）"
	var registered := {}
	for e in modules:
		registered[String(e["mod"])] = true
	var missing: Array[String] = []
	for member in FORWARDING_MEMBERS.keys():
		var path := String(FORWARDING_MEMBERS[member])
		if not registered.has(path):
			missing.append("%s→%s" % [member, path.get_file()])
			fails.append("宿主成员 `%s` 有薄包装转发到 %s，但它没登记在 MODULES —— 这些包装完全没被检查" % [
				member, path])
			print("    ✗ 覆盖漂移：`%s`（%s）未登记在 MODULES" % [member, path.get_file()])
	# 注：上面的表 ⊆ MODULES 只是**单向**断言。反向（MODULES 里有、表里没写）不 fail，
	# 因为表是"有薄包装的成员"清单；但"忘了往表里加新模块"同样会静默不覆盖，
	# 所以下面用高精度的注入形态探测补一条**提示**（只 note，不拦）。
	return "覆盖自检：声明了 %d 个转发成员，未登记 %d 个 ｜ 已登记模块 %d 个 %s" % [
		FORWARDING_MEMBERS.size(), missing.size(), modules.size(), _injection_note()]


## 用**注入形态**找出"疑似模块"的成员，作为覆盖面提示（只 note，不 fail）。
##
## 为什么只提示：任何"按代码长相推断"的判据都在这份宿主上失真，实测三条路都不成立 ——
##   · 按 `.new(self)`：宿主有两种注入风格，`.new()` + `setup(self)` 那种会漏。
##   · 按"单语句转发"：松了在 battle_scene.gd 上误报 40 个（局部变量 `p`/`u`/`out`、
##     循环体一行调用、连 `signal turn_started` 都长得一样）；紧了又漏掉带守卫与三元的真转发
##     （`if field != null:` + `field.clear()`、`return 0 if field == null else field.live_count()`）。
## 所以这里**只收两种高精度形态**，并且只打印提示，不参与 exit 判定：
##   ① `X = Cls.new(self)`                —— 构造注入宿主
##   ② `X = Cls.new()` 且紧邻 `X.setup(self` / `X.build(self` —— 构造后再注入宿主
## 其余 `.new()`（`_camera = Camera3D.new()` 后面跟属性赋值 / `add_child`）不进候选，所以零假阳性。
func _injection_note() -> String:
	const HOST := "res://src/view/battle_scene.gd"
	var f := FileAccess.open(HOST, FileAccess.READ)
	if f == null:
		return ""
	var lines := f.get_as_text().replace("\r\n", "\n").split("\n")
	var re_self := RegEx.create_from_string(
		"^\\s*([a-z_][a-z0-9_]*)\\s*=\\s*([A-Z][A-Za-z0-9_]*)\\.new\\(\\s*self\\s*\\)")
	var re_plain := RegEx.create_from_string(
		"^\\s*([a-z_][a-z0-9_]*)\\s*=\\s*([A-Z][A-Za-z0-9_]*)\\.new\\(\\s*\\)")
	var suspects := {}
	for i in range(lines.size()):
		var s := String(lines[i])
		var r := re_self.search(s)
		if r != null:
			suspects[r.get_string(1)] = r.get_string(2)
			continue
		var r2 := re_plain.search(s)
		if r2 == null:
			continue
		var var_name := r2.get_string(1)
		# 形态②：紧跟一行是同一个变量的 setup/build(self...)，才算"注入宿主"
		if i + 1 < lines.size():
			var nxt := String(lines[i + 1])
			if nxt.contains("%s.setup(self" % var_name) or nxt.contains("%s.build(self" % var_name):
				suspects[var_name] = r2.get_string(2)
	var unlisted: Array[String] = []
	for v in suspects.keys():
		if FORWARDING_MEMBERS.has(v) or FORWARDING_EXEMPT.has(v):
			continue
		unlisted.append("%s(%s)" % [v, suspects[v]])
	if unlisted.is_empty():
		return "｜ 注入候选 %d 个，全部已在表里或已豁免" % suspects.size()
	return "｜ **注入候选 %d 个，未列入表 %d 个：%s —— 请确认是否要覆盖**" % [
		suspects.size(), unlisted.size(), "、".join(unlisted)]


func _initialize() -> void:
	var fails: Array[String] = []
	var notes: Array[String] = []
	var checked := 0
	# 允许从命令行覆盖要检查的清单（自检用）：`-- --mod=<路径> --host=<路径> [--rename=a:b,c:d]`
	# 这样 check_wrappers_selftest.gd 可以用临时合成文件喂它，而不用改动本文件的常量。
	var modules: Array = MODULES
	var ua := OS.get_cmdline_user_args()
	var mod_override := ""
	var host_override := ""
	var rename_override := ""
	for a in ua:
		var s := String(a)
		if s.begins_with("--mod="):
			mod_override = s.substr(6)
		elif s.begins_with("--host="):
			host_override = s.substr(7)
		elif s.begins_with("--rename="):
			rename_override = s.substr(9)
	if mod_override != "":
		if mod_override == "-":
			print("═══ 包装层一致性检查：本轮无可检查的模块（空清单）═══")
			print("\n── 汇总 ──")
			print("检查了 0 个包装")
			print("✅ 包装层全部合规")
			quit(0)
			return
		var entry := {"mod": mod_override, "host": host_override}
		if rename_override != "":
			var rm := {}
			for pair in rename_override.split(","):
				var kv := String(pair).split(":")
				if kv.size() == 2:
					rm[String(kv[0])] = String(kv[1])
			entry["rename"] = rm
		modules = [entry]
	print("═══ 包装层一致性检查（协程性必须与模块函数一致）═══")
	var coverage_line := _check_coverage(modules, fails, host_override)

	for entry in modules:
		var mod_path: String = entry["mod"]
		var host_path: String = entry["host"]
		var mod_name := mod_path.get_file()
		var mod_funcs := _scan_funcs(mod_path)
		var host_funcs := _scan_funcs(host_path)
		var scan_only: Array = entry.get("scan_only", [])
		var mod_has: bool = mod_funcs.size() > 0
		if not mod_has:
			fails.append("读不到模块 %s" % mod_path)
			continue

		var mod_names: Array = mod_funcs.keys()
		mod_names.sort()
		print("\n── %s ──" % mod_name)
		for nm in mod_names:
			if SKIP.has(nm):
				continue
			if not scan_only.is_empty() and not scan_only.has(nm):
				continue                      # 只检查列出的包装名（其余是数据访问/工厂，天然无包装）
			var mod_is_coro: bool = bool(mod_funcs[nm]["is_coro"])
			var mod_ret: String = String(mod_funcs[nm]["ret"])
			# 命名映射：默认规则是"去掉/补上前导下划线"（提取时模块函数去下划线，
			# 宿主为了不打断测试的 `_s._xxx` 调用保留原名）；MODULES 里的 `rename`
			# 可以显式指定不一致的情况（哨兵模块的 tick/fire/lock）。
			var rename_map: Dictionary = entry.get("rename", {})
			# ① 签名一致性：参数个数 + **返回类型**
			#    只比参数个数是不够的：把返回类型收窄（`-> bool` 改成 `-> void`）既能编译、
			#    又能绕过协程性检查，而且如果这个包装恰好没有外部调用方，**连测试都不会炸** ——
			#    这是唯一能完全静默通过的路径（mod-fx 2026-10-04 用探针证出）。
			#    返回类型按 void 归一后再比：没写 `-> T` 就是 void，避免 `"" != "void"` 假阳性。
			var mod_ret_n := _norm_ret(String(mod_funcs[nm]["ret"]))
			var cand_ret_n := ""
			var host_name := ""
			var candidates: Array[String] = []
			if rename_map.has(nm):
				candidates.append(String(rename_map[nm]))
			if String(nm).begins_with("_"):
				candidates.append(String(nm).substr(1))       # 模块带下划线 -> 宿主无
			else:
				candidates.append("_" + String(nm))           # 模块无下划线 -> 宿主带
				candidates.append(String(nm))                 # 也可能同名
			for c in candidates:
				if not host_funcs.has(c):
					continue
				# 同名不代表同一个人：宿主自己可能有别的同名函数（例：哨兵模块的 `fire(sh)`
				# 会撞上 battle_scene 自有的 `_fire()`）。参数个数不同就跳过，
				# 免得报出"未发现转发"这种假警报。
				if int(host_funcs[c]["argc"]) != int(mod_funcs[nm]["argc"]):
					continue
				host_name = c
				cand_ret_n = _norm_ret(String(host_funcs[c]["ret"]))
				break
			if host_name == "":
				# 模块函数在宿主里没有同名包装 —— 不算错（可能只被模块内部调用），只提示
				print("    · %-26s 宿主无同名包装（模块内部调用 / 工厂直调）" % nm)
				continue
			var h: Dictionary = host_funcs[host_name]
			var host_is_coro: bool = bool(h["is_coro"])
			var call_form := _delegate_form(String(h["body"]), nm)
			checked += 1

			if cand_ret_n != mod_ret_n:
				fails.append("%s（-> %s.%s）：签名收窄/不一致 —— 模块返回 %s，包装返回 %s" % [
					host_name, mod_name, nm, mod_ret_n, cand_ret_n])
				print("    ✗ %-26s 返回类型不一致：模块 %s ｜ 包装 %s" % [nm, mod_ret_n, cand_ret_n])
				continue

			if call_form == "":
				print("    · %-26s 宿主包装（%s）未发现对 %s.%s(...) 的转发（人工确认）" % [
					nm, host_name, mod_name, nm])
				continue

			# ② 协程性必须一致（这是唯一"测试全绿但语义已变"的那类 bug）
			if host_is_coro != mod_is_coro:
				fails.append("%s（-> %s.%s）：模块协程=%s 但包装协程=%s（转发行：%s）" % [
					host_name, mod_name, nm, mod_is_coro, host_is_coro, call_form])
				print("    ✗ %-26s 模块协程=%-5s 包装协程=%-5s  %s" % [nm, mod_is_coro, host_is_coro, call_form])
				continue

			# ② 协程的转发行形态：有返回值 -> `return await`；void -> `await`
			#
			# 「模块有返回值、包装却只写 `await`」= **丢返回值**，这是必须拦的（fails）：
			# 它是"测试全绿但语义已变"的典型 —— 调用方拿到的不再是值，
			# 而现在没有任何调用方 await 它，所以 playtest 也照绿。
			# 反过来「包装写了 `return await` 但模块没写返回类型」只提示（notify）：
			# 那是模块自己的风格问题，有歧义，不该误杀。
			if mod_is_coro:
				if call_form.begins_with("return await "):
					if mod_ret == "void":
						notes.append("%s：包装用了 `return await`，但模块函数没写返回类型（请人工确认它是否真的返回值）" % host_name)
				elif call_form.begins_with("await "):
					if mod_ret != "void":
						# 「捕获再返回」（`var r = await mod.fn(...)` + `return r`）与 `return await` 等价，
						# 是合法写法，不能拦（否则门禁会拒绝正确代码，大家就会开始绕过它）。
						# 安全性：走到这里时签名检查已经保证 host_ret == mod_ret，
						# 所以"接住了值"不可能掩盖丢返回值。
						if not _await_result_captured(String(h["body"]), nm):
							fails.append("%s（-> %s.%s）：模块返回 %s 且是协程，包装只写 `await` 会**丢掉返回值**，必须写 `return await`（或捕获后 `return`）" % [
								host_name, mod_name, nm, mod_ret])
							print("    ✗ %-26s 丢返回值：模块返回 %s，包装只写 `await` 且没把结果交回" % [nm, mod_ret])
							continue
				elif call_form.contains("= await "):
					# `var r = await mod.fn(...)`：赋值形态，是否合法由上一条（_await_result_captured）判断
					if mod_ret != "void" and not _await_result_captured(String(h["body"]), nm):
						fails.append("%s（-> %s.%s）：模块返回 %s 且是协程，包装捕获了结果却没有 `return` 出去" % [
							host_name, mod_name, nm, mod_ret])
						print("    ✗ %-26s 捕获了 await 结果但没有 return 出去：%s" % [nm, call_form])
						continue
				else:
					fails.append("%s（-> %s.%s）：协程包装必须写 `await ...`、`return await ...` 或捕获后 `return`，实际：%s" % [
						host_name, mod_name, nm, call_form])
					print("    ✗ %-26s 协程包装缺少 await：%s" % [nm, call_form])
					continue
			print("    ✓ %-26s 模块协程=%-5s 包装协程=%-5s %s" % [nm, mod_is_coro, host_is_coro, call_form])

	print("\n── 汇总 ──")
	print("检查了 %d 个包装" % checked)
	print(coverage_line)
	if not notes.is_empty():
		print("提示（不影响结论）：")
		for n in notes:
			print("   · ", n)
	if fails.is_empty():
		print("✅ 包装层全部合规")
		quit(0)
	else:
		print("❌ 有 %d 处不一致：" % fails.size())
		for f in fails:
			print("   - ", f)
		quit(1)


## ── 扫描器：逐字符的括号深度解析（够用且不脆）──
## 只认行首（可有 tab 缩进）的 `func `；参数表按 `(` `)` 深度收齐，可以跨多行；
## 返回类型取参数表闭合 `)` 之后、行尾 `:` 之前的那段 `-> T`。
## 返回 {函数名: {"is_coro": bool, "ret": String, "argc": int, "body": String}}
func _scan_funcs(path: String) -> Dictionary:
	var out := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("打不开 %s" % path)
		return out
	var src := f.get_as_text().replace("\r\n", "\n")
	var at := 0
	while true:
		var fd := src.find("\nfunc ", at)
		fd = 0 if (fd < 0 and at == 0 and src.begins_with("func ")) else fd
		if fd < 0:
			break
		fd += 1                                   # 跳过换行，指向 'f'
		# 参数表：从第一个 '(' 开始按深度收齐
		var po := src.find("(", fd)
		if po < 0:
			break
		var depth := 0
		var pe := po
		var i := po
		while i < src.length():
			var ch := src[i]
			if ch == "(":
				depth += 1
			elif ch == ")":
				depth -= 1
				if depth == 0:
					pe = i
					break
			i += 1
		var args := src.substr(po + 1, pe - po - 1)
		var argc := 0
		if args.strip_edges() != "":
			argc = 1
			for ch2 in args:
				if ch2 == ",":
					argc += 1
		# 返回类型：`)` 之后到本行行尾，取 `-> T`
		var after := src.substr(pe + 1)
		var eol := after.find("\n")
		var sig_tail := after if eol < 0 else after.substr(0, eol)
		var ret := _ret_of(sig_tail)
		# 函数名
		var paren := src.find("(", fd)
		var name := src.substr(fd + 5, paren - fd - 5).strip_edges()
		# 函数体：签名行结束之后，直到【行首无缩进】的非空非注释行（= 下一个声明）为止
		var body_start := src.find("\n", pe)
		if body_start < 0:
			break
		body_start += 1
		var p := body_start
		var body_end := src.length()
		while p < src.length():
			var nl := src.find("\n", p)
			var line := src.substr(p, (src.length() - p) if nl < 0 else (nl - p))
			var t := line.strip_edges()
			var zero_indent := line.length() == line.lstrip(" \t").length()
			if t != "" and not t.begins_with("#") and zero_indent:
				body_end = p
				break
			if nl < 0:
				body_end = src.length()
				break
			p = nl + 1
		out[name] = _finish_body(src.substr(body_start, body_end - body_start).split("\n"), ret, argc)
		at = body_start
	return out


## 返回类型归一：GDScript 里没写 `-> T` 就是 void
static func _norm_ret(s: String) -> String:
	var t := s.strip_edges()
	return "void" if t == "" else t


## 从一段文本里抽 `-> T`（没有则返回 ""）。
## 空字符串统一按 "void" 归一：GDScript 里没写返回类型就是 void
## （不归一会让 `"" != "void"` 产生假阳性）。
static func _ret_of(s: String) -> String:
	var arrow := s.find("->")
	if arrow < 0:
		return ""
	var tail := s.substr(arrow + 2).strip_edges()
	var colon := tail.find(":")
	if colon >= 0:
		tail = tail.substr(0, colon).strip_edges()
	return tail


static func _finish_body(body: Array[String], ret: String, argc: int) -> Dictionary:
	var text := "\n".join(body)
	return {
		"is_coro": _has_await_stmt(body),
		"has_await_text": text.contains("await"),
		"ret": ret,
		"argc": argc,
		"body": text,
	}


## 体内是否存在【真正的 await 语句】（决定这个函数自己是不是协程）。
## 会被当成 await 语句的形态：
##   `await expr`          —— 行首
##   `x = await expr`      —— 赋值（含 `var x = await` 与带类型标注的 `var x: T = await`）
##   `return await expr`   —— 返回
## 反例（不算 await 语句，只是把协程**放走**、自己仍是同步函数）：
##   `volley_bullets(...)`             无 await
##   `return volley_bullets(...)`      只返回、不等待
##
## 注意：**不要**写成"await 只能出现在语句位置" —— 那是错的，
## `if await f():` / `print(await f())` 都是合法的表达式位置写法。
## 这里只覆盖**本仓实际使用的写法**；将来出现新写法（条件里 await 等），
## 这个函数会漏判成"同步"，那时要把它换成"去掉行尾注释后做 `await` 词匹配"。
static func _has_await_stmt(body: Array[String]) -> bool:
	for raw in body:
		var s := String(raw).strip_edges()
		if s == "" or s.begins_with("#"):
			continue
		if s.begins_with("await ") or s.begins_with("return await "):
			return true
		if s.find("= await ") >= 0:
			return true
	return false


## 在包装体里找"对模块函数的那次转发"，返回那一行（已 strip）；找不到返回 ""。
##
## ⚠️ **这是唯一的一份判定**：`_delegate_form()` 与 `_await_result_captured()` 都必须用它。
## 2026-10-04 踩过的坑：两处各写了一份 needle，`_delegate_form` 带 `.<fn>(` 兜底、
## 另一处只认 `模块文件名.<fn>(` —— 而宿主实际写的是 `attack.volley_bullets(...)`，
## 于是后者**恒返回 false**，"接纳捕获形态"的分支根本不可达，假阳性原样留着。
## 同一判定写两份就会漂移，所以收敛到这里。
##
## 为什么用 `.<fn>(` 作 needle：宿主是通过**实例变量**调模块的
## （`attack.volley_bullets(...)` / `sink.land_shell(...)` / `fx.draw_hints(...)`），
## 模块**文件名**（`basic_attack.gd`）根本不出现在包装体里。
static func _find_forward_line(body: String, fn: String) -> String:
	var needle_self := ".%s(" % fn
	for raw in body.split("\n"):
		var line := String(raw).strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		if line.contains(needle_self):
			return line
	return ""


## 从包装体里找出"对模块函数的转发"那一行，返回归一化后的形态：
##   "return await <...>" / "await <...>" / "<lhs> = await <...>" /
##   "return <...>" / "<...>"
## 找不到返回 ""。
static func _delegate_form(body: String, fn: String) -> String:
	var line := _find_forward_line(body, fn)
	if line == "":
		return ""
	if line.begins_with("return await "):
		return "return await " + line.substr(13)
	if line.begins_with("return "):
		return "return " + line.substr(7)
	if line.begins_with("await "):
		return "await " + line.substr(6)
	return line


## 包装是否**把 await 的结果接住并交回给调用方**？
## 合法形态：`var x = await <实例>.<fn>(...)` / `var x: T = await ...`，且体内有 `return x`。
## 这是与 `return await` 完全等价的写法（先存下来再返回），
## 不该被"丢返回值"那条规则误杀 —— 否则门禁会拦正确代码（假阳性）。
static func _await_result_captured(body: String, fn: String) -> bool:
	var line := _find_forward_line(body, fn)
	if line == "" or not line.contains("= await "):
		return false
	var eq := line.find("= await ")
	if eq <= 0:
		return false
	var lhs := line.substr(0, eq).strip_edges()
	if lhs.begins_with("var "):
		lhs = lhs.substr(4).strip_edges()
	var colon := lhs.find(":")
	if colon >= 0:
		lhs = lhs.substr(0, colon).strip_edges()
	if lhs == "" or not lhs.is_valid_identifier():
		return false
	for raw2 in body.split("\n"):
		if String(raw2).strip_edges() == "return %s" % lhs:
			return true
	return false
