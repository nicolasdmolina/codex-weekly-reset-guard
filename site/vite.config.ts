import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Relative base so the build works at a GitHub Pages project path
// (https://<user>.github.io/<repo>/) and at a custom domain root.
export default defineConfig({
  base: './',
  build: { license: { fileName: 'dependency-licenses.txt' } },
  plugins: [react()],
});
