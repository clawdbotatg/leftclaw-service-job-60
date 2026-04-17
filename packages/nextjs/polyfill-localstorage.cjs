// Polyfill localStorage for static export builds (Node lacks it, but some
// imported modules touch it at module evaluation time). Required during
// `next build` when NEXT_PUBLIC_IPFS_BUILD=true.
if (typeof globalThis.localStorage === "undefined") {
  const store = new Map();
  globalThis.localStorage = {
    getItem: key => (store.has(key) ? store.get(key) : null),
    setItem: (key, value) => {
      store.set(String(key), String(value));
    },
    removeItem: key => {
      store.delete(key);
    },
    clear: () => {
      store.clear();
    },
    key: i => Array.from(store.keys())[i] ?? null,
    get length() {
      return store.size;
    },
  };
}

if (typeof globalThis.sessionStorage === "undefined") {
  const store = new Map();
  globalThis.sessionStorage = {
    getItem: key => (store.has(key) ? store.get(key) : null),
    setItem: (key, value) => {
      store.set(String(key), String(value));
    },
    removeItem: key => {
      store.delete(key);
    },
    clear: () => {
      store.clear();
    },
    key: i => Array.from(store.keys())[i] ?? null,
    get length() {
      return store.size;
    },
  };
}
