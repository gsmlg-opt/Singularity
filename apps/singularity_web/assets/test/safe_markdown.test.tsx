import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import source from "../js/notes_workspace/safe_markdown.tsx?raw";
import { SafeMarkdown } from "../js/notes_workspace/safe_markdown";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

describe("SafeMarkdown", () => {
  let container: HTMLDivElement;
  let root: Root;

  beforeEach(() => {
    container = document.createElement("div");
    document.body.append(container);
    root = createRoot(container);
  });

  afterEach(async () => {
    await act(async () => root.unmount());
    container.remove();
  });

  async function renderMarkdown(markdown: string): Promise<void> {
    await act(async () => root.render(<SafeMarkdown markdown={markdown} />));
  }

  it("renders the approved prose Markdown elements from an AST", async () => {
    await renderMarkdown(`# Heading

Paragraph with *emphasis*, **strength**, and \`inline code\`.

- first
- second

> quotation

\`\`\`ts
const answer = 42
\`\`\`

---`);

    expect(container.querySelector("h1")?.textContent).toBe("Heading");
    expect(container.querySelector("p em")?.textContent).toBe("emphasis");
    expect(container.querySelector("p strong")?.textContent).toBe("strength");
    expect(container.querySelector("p code")?.textContent).toBe("inline code");
    expect([...container.querySelectorAll("li")].map((item) => item.textContent)).toEqual([
      "first",
      "second",
    ]);
    expect(container.querySelector("blockquote")?.textContent).toContain("quotation");
    expect(container.querySelector("pre code")?.textContent).toContain("const answer = 42");
    expect(container.querySelector("hr")).not.toBeNull();
  });

  it("allows only explicit web and mail links and hardens external links", async () => {
    await renderMarkdown(
      "[web](https://example.test/a) [plain](http://example.test/b) [mail](mailto:notes@example.test) [relative](/settings) [script](javascript:alert(1)) [data](data:text/html,unsafe)",
    );

    const links = [...container.querySelectorAll("a")];
    expect(links.map((link) => link.textContent)).toEqual(["web", "plain", "mail"]);
    expect(links.map((link) => link.getAttribute("href"))).toEqual([
      "https://example.test/a",
      "http://example.test/b",
      "mailto:notes@example.test",
    ]);
    for (const link of links) {
      expect(link.getAttribute("target")).toBe("_blank");
      expect(link.getAttribute("rel")).toBe("noopener noreferrer");
    }
    expect(container.textContent).toContain("relative");
    expect(container.textContent).toContain("script");
    expect(container.textContent).toContain("data");
  });

  it("renders raw HTML, scripts, and event handlers as inert text", async () => {
    const raw =
      '<script>globalThis.compromised = true</script>\n<button onclick="alert(1)">press</button>';
    await renderMarkdown(raw);

    expect(container.querySelector("script, button")).toBeNull();
    expect(container.textContent).toContain("<script>");
    expect(container.textContent).toContain("onclick");
    expect(
      (globalThis as typeof globalThis & { compromised?: boolean }).compromised,
    ).toBeUndefined();
  });

  it("makes Markdown images and HTML embeds resource-inert", async () => {
    await renderMarkdown(`![private diagram](https://resources.invalid/private.png)

<img src="https://resources.invalid/raw.png" onerror="alert(1)">
<iframe src="https://resources.invalid/frame"></iframe>
<video src="https://resources.invalid/movie"></video>`);

    expect(container.querySelector("img, iframe, embed, object, video, audio, source")).toBeNull();
    expect(container.textContent).toContain("private diagram");
    expect(container.textContent).toContain("<img");
    expect(container.textContent).toContain("<iframe");
    expect(container.textContent).toContain("<video");
    expect(container.innerHTML).not.toContain("resources.invalid/private.png");
  });

  it("never uses a raw HTML injection escape hatch", async () => {
    await renderMarkdown("<b onclick=alert(1)>unsafe</b>");

    expect(source).not.toContain("dangerouslySetInnerHTML");
    expect(container.innerHTML).not.toContain("dangerouslySetInnerHTML");
    expect(container.querySelector("b")).toBeNull();
  });
});
