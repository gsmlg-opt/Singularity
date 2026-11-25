# 出版书籍

用户在 Source → Manual → Add book 上传单个 EPUB，上限 1000 MiB。上传成功后打开 Knowledge 下的书籍详情，详情页可下载原文件。Knowledge → Published books 按添加时间倒序分页，全局搜索可以按书名找到书籍。

书籍属于 `published_book` 知识条目，通过 `items` 和现有手动来源记录存储。文件按 SHA-256 去重，原文件保存在 `DATA_DIR/published-books`。Styx 后台读取 EPUB 的容器清单和 OPF 书目元数据，不解压正文。文件名可作为初始书名。详情页显示处理中或提取失败的状态，提取失败时仍可下载原文件。

Source → Manual → Import books via SSH 接受 `user@host:/absolute/path`。服务端用 OpenSSH 的主机密钥校验和非交互认证，递归查找 EPUB 并逐个流式接收到 `DATA_DIR/book-imports`。服务端导入使用可用磁盘空间，可接收超过网页上限的原文件。任务可在浏览器关闭后继续，页面显示导入、重复和失败数量。目录包括 Calibre Library，源目录只读。

部署时通过 `BOOK_IMPORT_SSH_HOSTS` 配置允许的 SSH 目标（逗号分隔，匹配 `user@host` 或 SSH 配置别名）。在 Singularity 进程用户的 SSH 配置中提供私钥或 agent 和 `known_hosts`。容器运行时可将该配置作为只读挂载提供给 `/app/.ssh`。

ISBN 可以后补。导入范围是 EPUB 文件，Calibre SQLite 书目的读取和外部 ISBN 匹配另行处理。
