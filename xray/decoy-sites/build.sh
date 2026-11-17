#!/usr/bin/env bash
# Build every decoy site with Astro and pack each into dist/<site>.zip.
# Timestamps are fixed and entries sorted, so the same sources always give
# the same zip (no churn in git). The installer downloads these zips.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
npm ci --no-audit --no-fund
rm -rf build
mkdir -p dist

for directory in sites/*/; do
    site=$(basename "${directory}")
    DECOY_SITE="${site}" npx astro build
    (
        cd "build/${site}"
        find . -exec touch -h -t 202001010000 {} +
        rm -f "../../dist/${site}.zip.tmp"
        find . -type f | sed 's|^\./||' | LC_ALL=C sort | zip -X -q -@ "../../dist/${site}.zip.tmp"
    )
    mv "dist/${site}.zip.tmp" "dist/${site}.zip"
    echo "dist/${site}.zip: $(du -k "dist/${site}.zip" | cut -f1) KB"
done
