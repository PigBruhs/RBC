extends RefCounted
# 临时阳性对照：故意配一个不存在的字段，验证 --check-only 真的在做类型解析
static func bad(u: Unit) -> void:
	var x = u.definitely_not_a_field
	print(x)
