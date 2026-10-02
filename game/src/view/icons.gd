# ══════════════════════════════════════════════════════════════════════════════
# 队列图标生成：程序化画圆形图案（友军绿圈 / 敌军红圈，圈里画职业图形）
#   近战 = 剑、远程 = 弓、投掷 = 炸弹、假人 = 火柴人
# 全部用线段/圆点绘制，不依赖任何图片资源。
# ══════════════════════════════════════════════════════════════════════════════
class_name Icons
extends RefCounted

const SIZE := 84
const COL_PLAYER_RING := Color(0.30, 0.95, 0.45)
const COL_ENEMY_RING := Color(1.00, 0.35, 0.32)
const COL_FACE := Color(0.10, 0.12, 0.16)
const COL_GLYPH := Color(0.94, 0.96, 1.00)
const COL_DIM := Color(0.45, 0.47, 0.52)


static func make(role: int, side: int, is_dummy: bool, active: bool, skip: bool = false) -> ImageTexture:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := Vector2(SIZE * 0.5, SIZE * 0.5)
	var r := SIZE * 0.5 - 3.0
	var ring_col := COL_PLAYER_RING if side == UnitData.Side.PLAYER else COL_ENEMY_RING
	if skip:
		ring_col = COL_DIM
	var ring_w := 6.0 if active else 4.0

	# 圆环 + 内部深色底
	for y in SIZE:
		for x in SIZE:
			var p := Vector2(x + 0.5, y + 0.5)
			var d := p.distance_to(c)
			if d > r:
				continue
			img.set_pixel(x, y, COL_FACE)
			if d > r - ring_w:
				img.set_pixel(x, y, ring_col)
	# 当前行动者：外圈再套一圈亮环
	if active:
		for y in SIZE:
			for x in SIZE:
				var p := Vector2(x + 0.5, y + 0.5)
				var d := p.distance_to(c)
				if d > r + 2.0:
					continue
				if d > r:
					img.set_pixel(x, y, Color(1, 1, 1, 0.95))

	var glyph_col := COL_DIM if skip else COL_GLYPH
	if is_dummy:
		_figure(img, c, glyph_col)
	else:
		match role:
			UnitData.Role.MELEE: _sword(img, c, glyph_col)
			UnitData.Role.RANGED: _bow(img, c, glyph_col)
			UnitData.Role.THROWER: _bomb(img, c, glyph_col)
			_: _sword(img, c, glyph_col)
	return ImageTexture.create_from_image(img)


# ── 绘图原语 ──────────────────────────────────────────────────────────────────
static func _px(img: Image, x: int, y: int, col: Color) -> void:
	if x < 0 or y < 0 or x >= SIZE or y >= SIZE:
		return
	img.set_pixel(x, y, col)


static func _thick(img: Image, a: Vector2, b: Vector2, w: float, col: Color) -> void:
	var steps := int(maxf(8.0, a.distance_to(b) * 3.0))
	var half := w * 0.5
	for i in steps + 1:
		var t := float(i) / float(steps)
		var p := a.lerp(b, t)
		var x0 := int(round(p.x - half))
		var x1 := int(round(p.x + half))
		var y0 := int(round(p.y - half))
		var y1 := int(round(p.y + half))
		for yy in range(y0, y1 + 1):
			for xx in range(x0, x1 + 1):
				_px(img, xx, yy, col)


static func _disc(img: Image, c: Vector2, r: float, col: Color) -> void:
	for y in range(int(c.y - r) - 1, int(c.y + r) + 2):
		for x in range(int(c.x - r) - 1, int(c.x + r) + 2):
			if Vector2(x + 0.5, y + 0.5).distance_to(c) <= r:
				_px(img, x, y, col)


static func _ring(img: Image, c: Vector2, r: float, w: float, col: Color) -> void:
	for y in range(int(c.y - r) - 2, int(c.y + r) + 3):
		for x in range(int(c.x - r) - 2, int(c.x + r) + 3):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			if d <= r and d >= r - w:
				_px(img, x, y, col)


# ── 四个图形 ──────────────────────────────────────────────────────────────────
## 剑：竖刃 + 横护手 + 短柄
static func _sword(img: Image, c: Vector2, col: Color) -> void:
	var tip := c + Vector2(0, -24)
	var hilt := c + Vector2(0, 14)
	_thick(img, hilt, tip, 6.0, col)
	# 剑尖收窄
	_thick(img, tip + Vector2(0, 4), tip, 3.0, col)
	# 护手
	_thick(img, c + Vector2(-14, 10), c + Vector2(14, 10), 5.0, col)
	# 柄
	_thick(img, c + Vector2(0, 10), c + Vector2(0, 22), 5.0, col)
	_disc(img, c + Vector2(0, 24), 3.5, col)


## 弓：一段弧 + 弦
static func _bow(img: Image, c: Vector2, col: Color) -> void:
	var bulge := 18.0
	var top := c + Vector2(-6, -22)
	var bot := c + Vector2(-6, 22)
	# 弓臂（左右两段折线近似弧）
	_thick(img, top, c + Vector2(bulge - 6, 0), 5.0, col)
	_thick(img, c + Vector2(bulge - 6, 0), bot, 5.0, col)
	# 弓弦
	_thick(img, top, bot, 2.2, col)
	# 箭
	_thick(img, c + Vector2(-16, 0), c + Vector2(22, 0), 3.0, col)
	_thick(img, c + Vector2(22, 0), c + Vector2(15, -6), 2.4, col)
	_thick(img, c + Vector2(22, 0), c + Vector2(15, 6), 2.4, col)


## 炸弹：圆球 + 引线 + 火花
static func _bomb(img: Image, c: Vector2, col: Color) -> void:
	var bc := c + Vector2(0, 6)
	_disc(img, bc, 16.0, col)
	# 高光（挖个洞，纯色下也能看出球形）
	_disc(img, bc + Vector2(-5, -5), 4.0, COL_FACE)
	# 引线
	_thick(img, bc + Vector2(4, -15), bc + Vector2(12, -26), 2.6, col)
	# 火花
	for off in [Vector2(0, -3), Vector2(-3, 0), Vector2(3, 0), Vector2(0, 3), Vector2(0, 0)]:
		_disc(img, bc + Vector2(13, -28) + off, 2.0, col)


## 假人：火柴人（圆头 + 身体 + 四肢）
static func _figure(img: Image, c: Vector2, col: Color) -> void:
	var head := c + Vector2(0, -18)
	_ring(img, head, 7.0, 3.0, col)
	_thick(img, c + Vector2(0, -11), c + Vector2(0, 10), 3.2, col)          # 身
	_thick(img, c + Vector2(-13, -3), c + Vector2(13, -3), 3.0, col)        # 臂
	_thick(img, c + Vector2(0, 10), c + Vector2(-9, 24), 3.0, col)          # 腿
	_thick(img, c + Vector2(0, 10), c + Vector2(9, 24), 3.0, col)
