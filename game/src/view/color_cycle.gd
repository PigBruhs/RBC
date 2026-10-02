# ══════════════════════════════════════════════════════════════════════════════
# 彩色流动（用户要求）
#
# 用途：表示"等待确认"的状态。不再用静态图标，而是让高亮边缘的颜色
#       以连续、恒定速度循环渐变（彩虹流转），一眼就能看出"这个还没确认"。
#
# 设计要点：
#   · 颜色 = HSV(hue, 1, 1)，hue 随时间线性增长，所以颜色变化是**连续且匀速**的
#   · 每个高亮可以带一个相位偏移 phase，让几个高亮之间有色差、不会整片同色
#   · 全部通过 set_material / tick 驱动，不需要 Shader（好调试、跨平台稳）
# ══════════════════════════════════════════════════════════════════════════════
class_name ColorCycle
extends RefCounted

## 走完一整圈彩虹要多久（秒）。太小会闪得难受，太大又看不出在动。
const PERIOD := 2.6

## 颜色变化的快慢（hue/秒）
static func rate() -> float:
	return 1.0 / PERIOD


## 取当前颜色。phase 用于给不同对象错开色相（0~1）
static func color_at(t: float, phase: float = 0.0, alpha: float = 1.0) -> Color:
	var h := fposmod(t * rate() + phase, 1.0)
	return Color.from_hsv(h, 1.0, 1.0, alpha)


## 取"偏亮/偏暗"版本，用于描边（同色相、不同明度），保证边缘比填充更显眼
static func edge_at(t: float, phase: float = 0.0, alpha: float = 1.0) -> Color:
	var h := fposmod(t * rate() + phase, 1.0)
	return Color.from_hsv(h, 1.0, 1.0, alpha)


## 取填充版（半透明）
static func fill_at(t: float, phase: float = 0.0, alpha: float = 0.35) -> Color:
	var h := fposmod(t * rate() + phase, 1.0)
	return Color.from_hsv(h, 0.85, 1.0, alpha)
