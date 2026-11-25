# GitHub Trending 语言自动补全实施计划

1. 从 GitHub Trending 的 Language 菜单提取去重后的显示名称和 slug，纳入采集器的配置字段元数据。
2. 用 `dm_input` 和 Duskmoon Core 的自动补全样式在输入框下方展示建议，保留原字段名、空值和已保存的值。
3. Range 切换时更新默认间隔，保留手填值。用 LiveView 测试覆盖选项、保存和回显，通过浏览器验证键盘选择与间隔联动，并运行格式检查、严格编译和完整测试。
