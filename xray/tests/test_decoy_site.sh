#!/usr/bin/env bash
#
# Decoy sites: the menu table, and deploying each built zip from
# xray/decoy-sites/dist the way the installer does (placeholders filled per
# install, marker written, the node page named after the domain), plus keeping
# the old site when an archive is incomplete. downloadFile and curl are stubs.

# Globals are shared with the sourced modules, which ShellCheck cannot see.
# shellcheck disable=SC2034,SC2154

set -euo pipefail

testDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${testDirectory}/load_modules.sh"
siteZips="${testDirectory}/../decoy-sites/dist"

temporaryDirectory=$(mktemp -d /tmp/xray-decoy-site-test.XXXXXX)
trap 'rm -rf "${temporaryDirectory}"' EXIT

echoContent() { :; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# --- menu table ----------------------------------------------------------------
[[ ${#nginxTemplates[@]} -eq 6 ]] || fail "expected 6 decoy sites, got ${#nginxTemplates[@]}"
[[ "$(nginxTemplateArchive 1)" == "${decoySiteBase}/corp-cn.zip" ]] || fail "site 1 archive: $(nginxTemplateArchive 1)"
for choice in 0 7 x ""; do
    nginxTemplateArchive "${choice}" >/dev/null && fail "'${choice}' is not a decoy site"
done
for entry in "${nginxTemplates[@]}"; do
    [[ -f "${siteZips}/${entry#*|}.zip" ]] || fail "no built zip for ${entry} (run xray/decoy-sites/build.sh)"
done

# --- deploying every site ------------------------------------------------------
downloadFile() { cp "${siteZips}/${1##*/}" "$2"; }
curl() { printf 'ip=203.0.113.7\nloc=NL\n'; }
domain=vod-s1.example.com
nginxStaticPath="${temporaryDirectory}/www/"
mkdir -p "${nginxStaticPath}"
for ((number = 1; number <= ${#nginxTemplates[@]}; number++)); do
    site=${nginxTemplates[number - 1]#*|}
    deployNginxTemplate "${number}" || fail "${site}: deploy failed"
    [[ -f "${nginxStaticPath}/index.html" && -f "${nginxStaticPath}/check" ]] || fail "${site}: page or marker missing"
    leftover=$(grep -rhoE '__[A-Z0-9_]+__' "${nginxStaticPath}" --include='*.html' --include='*.json' | sort -u | tr '\n' ' ' || true)
    [[ -z "${leftover}" ]] || fail "${site}: unfilled placeholders: ${leftover}"
    grep -q 'style="--hue:[0-9]\{1,3\}"' "${nginxStaticPath}/index.html" || fail "${site}: colour hue not filled"
    grep -q 'vod-s1.example.com' -r "${nginxStaticPath}" --include='*.html' || fail "${site}: domain not filled"
    external=$(grep -rhoE '(src|href)="(https?:)?//[^"]+' "${nginxStaticPath}" --include='*.html' | sort -u | tr '\n' ' ' || true)
    [[ -z "${external}" ]] || fail "${site}: external resources: ${external}"
    grep -q '<meta name="generator" content="Astro' "${nginxStaticPath}/index.html" || fail "${site}: not an Astro build"
done
# The last one is the resource node: named and typed after the domain, with
# a machine-readable status, and no addresses or downloadable files.
jq -e '.node == "vod-s1" and .service == "vod" and .region == "NL" and .status == "ok"' "${nginxStaticPath}/status.json" >/dev/null \
    || fail "status.json: $(cat "${nginxStaticPath}/status.json")"
grep -q '<title>vod-s1 · Media Edge Node</title>' "${nginxStaticPath}/index.html" || fail "the node page is named after the domain"
grep -q '203.0.113.7' "${nginxStaticPath}/index.html" && fail "the node page must not show the server address"
[[ ! -e "${nginxStaticPath}/speedtest" ]] || fail "no downloadable test files"
[[ "$(decoyResourceNode img2.example.com | sed -n 's/^SERVICE_ID=//p')" == static ]] || fail "img* hosts are static nodes"
[[ "$(decoyResourceNode dl.example.com | sed -n 's/^SERVICE_ID=//p')" == download ]] || fail "dl* hosts are download nodes"
[[ "$(decoyResourceNode example.com | sed -n 's/^NODE=//p')" =~ ^edge-[0-9]{2}$ ]] || fail "a bare domain gets a generic node name"

# Blogs: every post page is filled too.
deployNginxTemplate 4 || fail "tech blog deploy failed"
[[ $(find "${nginxStaticPath}/posts" -name index.html | wc -l) -ge 3 ]] || fail "tech blog post pages missing"

# Per install: two deployments of the same site differ (names, colours, dates).
first=$(cat "${nginxStaticPath}/index.html")
for _ in 1 2 3 4 5; do
    deployNginxTemplate 4
    [[ "$(cat "${nginxStaticPath}/index.html")" != "${first}" ]] && break
done
[[ "$(cat "${nginxStaticPath}/index.html")" != "${first}" ]] || fail "repeated deployments should not serve identical pages"

# --- an incomplete archive keeps the working site ------------------------------
mkdir -p "${temporaryDirectory}/broken/nothing" && touch "${temporaryDirectory}/broken/nothing/file"
(cd "${temporaryDirectory}/broken" && zip -qr "${temporaryDirectory}/broken.zip" .)
downloadFile() { cp "${temporaryDirectory}/broken.zip" "$2"; }
deployNginxTemplate 1 && fail "an archive without index.html must be refused"
[[ -d "${nginxStaticPath}/posts" ]] || fail "the working site must be kept"

echo "decoy site tests passed"
