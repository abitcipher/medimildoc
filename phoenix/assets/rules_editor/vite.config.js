// Builds the rule editor into priv/static/assets/rules_editor/ (served and
// digested with the other static assets). docs/design/data-consistency.md.
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "/assets/rules_editor/",
  build: {
    outDir: "../../priv/static/assets/rules_editor",
    emptyOutDir: true,
    sourcemap: false,
    chunkSizeWarningLimit: 8000,
    lib: {
      entry: "src/main.jsx",
      formats: ["es"],
      fileName: () => "rules_editor.js",
      cssFileName: "rules_editor",
    },
    rollupOptions: { output: { chunkFileNames: "[name]-[hash].js", assetFileNames: "[name][extname]" } },
  },
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
  worker: { format: "es" },
});
