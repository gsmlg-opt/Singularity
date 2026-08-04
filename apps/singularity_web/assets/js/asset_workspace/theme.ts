export type Theme = "light" | "dark";

const storageKey = "singularity.asset-theme";

type ThemeOptions = {
  root?: HTMLElement | null;
  storage?: Pick<Storage, "getItem" | "setItem"> | null;
  matchMedia?: typeof window.matchMedia | null;
};

function validTheme(value: unknown): Theme | null {
  return value === "light" || value === "dark" ? value : null;
}

function defaultRoot(): HTMLElement | null {
  try {
    return typeof document === "undefined" ? null : document.documentElement;
  } catch {
    return null;
  }
}

function defaultStorage(): Storage | null {
  try {
    return typeof window === "undefined" ? null : window.localStorage;
  } catch {
    return null;
  }
}

function defaultMatchMedia(): typeof window.matchMedia | null {
  try {
    return typeof window === "undefined" || typeof window.matchMedia !== "function"
      ? null
      : window.matchMedia.bind(window);
  } catch {
    return null;
  }
}

export function readTheme(options: ThemeOptions = {}): Theme {
  const root = options.root === undefined ? defaultRoot() : options.root;

  try {
    const rootTheme = validTheme(root?.dataset.theme);
    if (rootTheme) {
      return rootTheme;
    }
  } catch {
    // Continue through the safe fallbacks.
  }

  const storage = options.storage === undefined ? defaultStorage() : options.storage;

  try {
    const storedTheme = validTheme(storage?.getItem(storageKey));
    if (storedTheme) {
      return storedTheme;
    }
  } catch {
    // Continue through the safe fallbacks.
  }

  const matchMedia = options.matchMedia === undefined ? defaultMatchMedia() : options.matchMedia;

  try {
    return matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  } catch {
    return "light";
  }
}

export function applyTheme(
  value: unknown,
  options: Pick<ThemeOptions, "root" | "storage"> = {},
): Theme {
  const theme = validTheme(value) ?? "light";
  const root = options.root === undefined ? defaultRoot() : options.root;

  try {
    if (root) {
      root.dataset.theme = theme;
    }
  } catch {
    // A restricted root must not prevent the caller from choosing a theme.
  }

  const storage = options.storage === undefined ? defaultStorage() : options.storage;

  try {
    storage?.setItem(storageKey, theme);
  } catch {
    // Storage may be unavailable in private or restricted browser contexts.
  }

  return theme;
}
