# 出版书籍实施计划

1. 在 `Singularity.Knowledge` 接入 EPUB 上传、列表、详情、下载和手动来源记录。用 `Singularity.DataDir` 保存文件，按内容查重；使用 Styx worker 从 `Singularity.Documents` 异步提取书名和作者。
2. 在 Source → Manual 接入 LiveView 上传表单，在 Knowledge → Published books 接入 DuskMoon 表格、详情下载、全局搜索与 gettext。
3. 测试有效和无效的 EPUB、重复上传、异步提取、下载原始字节和全局搜索。运行格式检查、严格编译和完整测试，在本机 devenv 服务验收并截图。
4. 网页上传提高到 1000 MiB。改用随机访问 ZIP 的小型元数据条目，验证 Calibre 文件头和大文件路径。Source → Manual 的 SSH 导入以 Styx 排队，复用书籍保存和去重，验证目录递归、重跑、单文件失败及 DSM 连接。
