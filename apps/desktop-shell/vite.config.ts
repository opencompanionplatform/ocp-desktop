import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  base: "./",
  build: {
    outDir: "dist-renderer",
    emptyOutDir: true,
    sourcemap: process.env.OCP_DESKTOP_SHELL_SOURCEMAP === "1",
    chunkSizeWarningLimit: 550,
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (!id.includes("node_modules")) return undefined;
          if (id.includes("@assistant-ui/")) return "assistant-ui";
          if (id.includes("lucide-react")) return "icons";
          if (id.includes("/motion/")) return "motion";
          if (
            id.includes("/react/")
            || id.includes("/react-dom/")
            || id.includes("/scheduler/")
            || id.includes("/use-sync-external-store/")
          ) return "react";
          return undefined;
        },
      },
    },
  },
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
  },
});
