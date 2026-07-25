// @ts-check
import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';
import sitemap from '@astrojs/sitemap';

// The hellotham organisation's Pages site uses the custom domain
// hellotham.com, so this project site is served at hellotham.com/finvestlens/
// — NOT hellotham.github.io. `site` must name the domain the pages actually
// answer on, or canonical URLs, og:url, the sitemap and the JSON-LD all point
// somewhere else. `base` is the repository name, or every asset 404s.
export default defineConfig({
  site: 'https://hellotham.com',
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
