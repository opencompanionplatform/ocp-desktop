import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  base: "./",
  plugins: [react()],
  build: {
    // wasm-media-encoders is already lazy-loaded only when OGG export is used.
    // Keep it as an isolated on-demand chunk and split the normal Studio vendors.
    chunkSizeWarningLimit: 820,
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (!id.includes("node_modules")) return undefined;
          if (id.includes("wasm-media-encoders")) return "media-encoders";
          if (id.includes("@supabase/")) return "supabase";
          if (id.includes("jszip")) return "jszip";
          if (id.includes("/react/") || id.includes("/react-dom/")) return "react";
          return "vendor";
        },
      },
    },
  },
  server: {
    port: 5184,
    strictPort: true,
    proxy: {
      "/v1": "http://localhost:8788"
    }
  }
});
