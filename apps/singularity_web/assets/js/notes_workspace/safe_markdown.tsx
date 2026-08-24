import type { ComponentPropsWithoutRef, ReactNode } from "react";
import ReactMarkdown from "react-markdown";

type MarkdownNode = {
  type: string;
  value?: string;
  children?: MarkdownNode[];
};

const allowedElements = [
  "a",
  "blockquote",
  "br",
  "code",
  "em",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "hr",
  "img",
  "li",
  "ol",
  "p",
  "pre",
  "strong",
  "ul",
];

function makeRawHtmlInert(node: MarkdownNode): void {
  if (node.type === "html") {
    node.type = "text";
    delete node.children;
    return;
  }

  for (const child of node.children ?? []) makeRawHtmlInert(child);
}

function inertRawHtml() {
  return (tree: MarkdownNode): void => makeRawHtmlInert(tree);
}

function safeUrl(value: string): string {
  try {
    const protocol = new URL(value).protocol.toLowerCase();
    return protocol === "http:" || protocol === "https:" || protocol === "mailto:" ? value : "";
  } catch {
    return "";
  }
}

function SafeLink({ href, children, ...props }: ComponentPropsWithoutRef<"a">): ReactNode {
  if (!href) return <span>{children}</span>;

  return (
    <a {...props} href={href} target="_blank" rel="noopener noreferrer">
      {children}
    </a>
  );
}

function InertImage({ alt }: ComponentPropsWithoutRef<"img">): ReactNode {
  return <span className="notes-preview-image">{alt || "Image"}</span>;
}

export function SafeMarkdown({ markdown }: { markdown: string }) {
  return (
    <ReactMarkdown
      remarkPlugins={[inertRawHtml]}
      allowedElements={allowedElements}
      urlTransform={safeUrl}
      components={{ a: SafeLink, img: InertImage }}
    >
      {markdown}
    </ReactMarkdown>
  );
}
