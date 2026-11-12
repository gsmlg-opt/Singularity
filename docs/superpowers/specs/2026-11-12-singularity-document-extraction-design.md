# 文档提取基础（xberg）

日期：2026-11-12。在 v2（`2026-11-11-singularity-knowledge-v2-design.md`）之上，不取代其中任何内容。

## 1. 目标

Singularity 将来要导入各种文档（PDF、Office、EPUB、HTML 等）。这一版只做准备：接入 [xberg](https://github.com/xberg-io/xberg)，提供一个统一的文档提取入口，供以后的文档导入使用。

这一版不加数据模型、不加界面、没有调用方。

成功标准：

1. `Singularity.Documents.extract/2` 能把本地的 `.md`、`.html`、`.pdf` 文件提取为 Markdown，并返回 MIME 类型和标题。
2. 损坏的文件返回 `{:error, _}`，不抛异常、不让 VM 崩溃。
3. xberg 的 NIF 在 `devenv shell -- mix test` 和 `mix release` 产物中都能加载。

## 2. 依赖

- `apps/singularity` 加 `{:xberg, "~> 1.3.10"}`。
- 使用 `rustler_precompiled` 的预编译 NIF（x86_64-unknown-linux-gnu，NIF 2.16），本机不装 Rust 工具链。
- 不启用 OCR、转写、embedding，不需要 Tesseract 或 ONNX Runtime。
- xberg 不是自维护的库（不在自维护组织内）。它的缺陷不适用"去上游提 issue、不在本地绕过"的规则，但所有对它的引用都限制在一个 adapter 模块内（见 §3）。

调用方式是进程内 NIF。xberg 的提取函数是 `DirtyCpu` NIF，不阻塞普通调度器。Rust panic 由 Rustler 转成错误；底层 C 库的段错误仍会让 VM 崩溃，这一版接受这个风险。需要隔离时，另写一个调用 `xberg serve` 的 adapter，不改上下文接口。

## 3. 模块

### 3.1 `Singularity.Documents`（新上下文）

公开函数：

    extract(path, opts \\ [])
      :: {:ok, %{content: String.t(), mime_type: String.t(), title: String.t() | nil, metadata: map()}}
       | {:error, :not_a_file | :too_large | {:extract_failed, String.t()}}

- 只接受存在的本地普通文件路径。URL（`http://`、`https://`、`file://` 等任何带 scheme 的字符串）、目录、不存在的路径都返回 `{:error, :not_a_file}`。这样所有网络请求仍只经过 `Singularity.HttpClient` 和限速队列。
- 选项：
  - `:mime_type`：指定 MIME 类型，覆盖自动检测。
  - `:max_bytes`：文件大小上限，默认 50 MB（52_428_800 字节）；超过返回 `{:error, :too_large}`，不调用提取器。
- `content` 是 Markdown。
- `title` 取自文档元数据；没有则为 `nil`。
- `metadata` 是提取器给出的其余元数据，键为字符串。
- 检查通过后调用配置的提取器：`Application.get_env(:singularity, :document_extractor, Singularity.Documents.XbergExtractor)`。

### 3.2 `Singularity.Documents.Extractor`（behaviour）

    @callback extract(path :: Path.t(), opts :: keyword()) ::
                {:ok, %{content: String.t(), mime_type: String.t(), title: String.t() | nil, metadata: map()}}
                | {:error, {:extract_failed, String.t()}}

opts 只会带 `:mime_type`。

### 3.3 `Singularity.Documents.XbergExtractor`

- 唯一引用 `Xberg.*` 的模块。
- 用 `kind: :uri` 传本地路径，不用 `kind: :bytes`。xberg 1.3.10 在调用 NIF 前用 `Jason.encode!` 编码输入，非 UTF-8 的二进制（如 PDF）会抛 `Jason.EncodeError`（已验证）。
- 配置 `output_format: :markdown`，OCR 关闭。
- 取 `output.results` 的第一个结果，映射为 §3.2 的返回结构。
- 任何错误（`{:error, _}`、异常、空结果）都返回 `{:error, {:extract_failed, message}}`，不抛异常。

## 4. 测试

- `Singularity.DocumentsTest`：用测试替身提取器（在 test 配置中设置 `:document_extractor`），覆盖：
  - 正常文件交给提取器，并原样返回结果。
  - URL、目录、不存在的路径返回 `:not_a_file`，且不调用提取器。
  - 超过 `:max_bytes` 返回 `:too_large`，且不调用提取器。
  - `:mime_type` 透传给提取器。
- `Singularity.Documents.XbergExtractorTest`：直接调用真实的 xberg，默认运行。fixture 放在 `apps/singularity/test/fixtures/documents/`：
  - `sample.md`、`sample.html`、`sample.pdf`：断言提取出的文字和 MIME 类型。
  - `corrupt.pdf`：返回 `{:error, {:extract_failed, _}}`。fixture 必须是 xberg 无法解析的 PDF；只截断尾部的 PDF 会被 xberg 容错，返回空内容的 `{:ok, _}`。
- 内容为空不算失败（例如关闭 OCR 时的扫描件），仍返回 `{:ok, _}`。
- 发布检查：`MIX_ENV=prod mix release` 后，在 release 中运行 `Singularity.Documents.extract/2` 处理 `sample.pdf`，能正常返回。

## 5. 不做

- 文档知识类型、上传、界面、导入任务。
- OCR、转写、embedding、分块、结构化提取。
- 用 xberg 获取 URL 或爬取网页。
- `xberg serve` / CLI 调用方式。

以上每一项需要时另写 spec。

## 6. 文档

AGENTS.md 技术栈加一行：文档提取用 xberg（外部库，只经过 `Singularity.Documents`，不是自维护的库）。
