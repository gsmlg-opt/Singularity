import { describe, expect, it, vi } from "vitest";

import { applyTheme, readTheme } from "../js/asset_workspace/theme";

function memoryStorage(initial: Record<string, string> = {}): Storage {
  const values = new Map(Object.entries(initial));

  return {
    get length() {
      return values.size;
    },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => values.delete(key),
    setItem: (key, value) => values.set(key, value),
  };
}

describe("workspace theme", () => {
  it("prefers a valid root theme, then storage, then the system preference", () => {
    const root = document.createElement("html");
    const storage = memoryStorage({ "singularity.asset-theme": "dark" });
    const matchMedia = vi.fn(() => ({ matches: false })) as unknown as typeof window.matchMedia;

    root.dataset.theme = "light";
    expect(readTheme({ root, storage, matchMedia })).toBe("light");

    delete root.dataset.theme;
    expect(readTheme({ root, storage, matchMedia })).toBe("dark");

    storage.removeItem("singularity.asset-theme");
    matchMedia.mockReturnValue({ matches: true } as MediaQueryList);
    expect(readTheme({ root, storage, matchMedia })).toBe("dark");
  });

  it("applies only light or dark to the root and persists it safely", () => {
    const root = document.createElement("html");
    const storage = memoryStorage();

    expect(applyTheme("dark", { root, storage })).toBe("dark");
    expect(root.dataset.theme).toBe("dark");
    expect(storage.getItem("singularity.asset-theme")).toBe("dark");

    expect(applyTheme("not-a-theme", { root, storage })).toBe("light");
    expect(root.dataset.theme).toBe("light");
    expect(storage.getItem("singularity.asset-theme")).toBe("light");
  });

  it("falls back safely when browser preference or storage access fails", () => {
    const root = document.createElement("html");
    const storage = {
      getItem: () => {
        throw new DOMException("blocked");
      },
      setItem: () => {
        throw new DOMException("blocked");
      },
    } as unknown as Storage;
    const matchMedia = (() => {
      throw new DOMException("unavailable");
    }) as typeof window.matchMedia;

    expect(readTheme({ root, storage, matchMedia })).toBe("light");
    expect(() => applyTheme("dark", { root, storage })).not.toThrow();
    expect(root.dataset.theme).toBe("dark");
  });
});
