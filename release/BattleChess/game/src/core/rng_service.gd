# ══════════════════════════════════════════════════════════════════════════════
# 可复现随机：32 位 LCG（纯整数，无浮点比较；状态只有 uint32，可完整进存档）
# ══════════════════════════════════════════════════════════════════════════════
class_name RngService
extends RefCounted

const A: int = 1664525
const C: int = 1013904223
const MASK: int = 0xFFFFFFFF

var state: int = 0

func _init(seed_value: int = 0) -> void:
	state = seed_value & MASK

func next_u32() -> int:
	state = (A * state + C) & MASK
	return state

func next_int(bound: int) -> int:
	assert(bound > 0)
	return next_u32() % bound

## [1,100] 的掷骰
func roll_100() -> int:
	return next_int(100) + 1

func percent(pct: int) -> bool:
	if pct <= 0: return false
	if pct >= 100: return true
	return roll_100() <= pct

## [0,1) 的浮点（散步取角度/半径用）。用 2^32 归一化，和整数路径共享同一个状态。
func next_float() -> float:
	return float(next_u32()) / 4294967296.0
