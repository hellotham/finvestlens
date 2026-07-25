// @ts-check
import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';
import sitemap from '@astrojs/sitemap';

// GitHub Pages serves a project site from https://<owner>.github.io/<repo>/,
// so `base` must match the repository name or every asset and link 404s.
// Both live here alone — change them in one place to move the site.
export default defineConfig({
  site: 'https://hellotham.github.io',
  base: '/finvestlens',
  trailingSlash: 'always',
  output: 'static',
  integrations: [sitemap()],
  build: { format: 'directory' },
  vite: {
    // Tailwind 4 ships a Vite plugin; the old @astrojs/tailwind integration
    // is deprecated.
    plugins: [tailwindcss()],
  },
});
