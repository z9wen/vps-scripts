// One Astro project, one site per build: DECOY_SITE picks the directory
// under ./sites, which holds that site's pages (and posts for the blogs).
import { defineConfig } from "astro/config";

const site = process.env.DECOY_SITE;
if (!site) {
  throw new Error("Set DECOY_SITE to a directory in ./sites, or run ./build.sh");
}

export default defineConfig({
  srcDir: `./sites/${site}`,
  publicDir: `./sites/${site}/public`,
  outDir: `./build/${site}`,
  cacheDir: `./node_modules/.astro-cache/${site}`,
  // Hashed stylesheets under /_astro/, as on any built Astro site.
  build: { inlineStylesheets: "never" },
  devToolbar: { enabled: false },
});
