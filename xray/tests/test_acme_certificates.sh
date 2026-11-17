#!/usr/bin/env bash
#
# Certificates issued on the host by acme.sh (acme_manage.sh layout, also in
# a custom home) or certbot: host name matching, discovery, selection,
# deploying without touching the client's own settings, and the daily sync of
# renewed certificates. Uses real openssl; acme.sh, crontab, systemctl and
# restartXray are stubs.

# Globals are shared with the sourced modules, which ShellCheck cannot see.
# shellcheck disable=SC2034,SC2154

set -euo pipefail

testDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${testDirectory}/load_modules.sh"

# Resolved (macOS /tmp is a symlink), as detectLocalAcmeHomes prints homes.
temporaryDirectory=$(cd "$(mktemp -d /tmp/xray-acme-test.XXXXXX)" && pwd -P)
trap 'rm -rf "${temporaryDirectory}"' EXIT

echoContent() { :; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Usage: installAcme <home>  (a stub acme.sh that logs its calls)
installAcme() {
    mkdir -p "$1"
    printf '#!/usr/bin/env bash\necho "$*" >>"%s/calls.log"\n' "${temporaryDirectory}" >"$1/acme.sh"
    chmod +x "$1/acme.sh"
}

# Usage: issueCertificate <certificate directory> <main domain> <SAN list> [certificate file] [key file]
issueCertificate() {
    local cert=${4:-$2.cer} key=${5:-$2.key}
    mkdir -p "$1"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 -subj "/CN=$2" \
        -addext "subjectAltName=$3" -keyout "$1/${key}" -out "$1/${cert}" >/dev/null 2>&1
    if [[ -z "${4:-}" ]]; then
        cp "$1/${cert}" "$1/fullchain.cer"
        printf "Le_Domain='%s'\nLe_RealFullChainPath='/etc/nginx/ssl/blog.pem'\nLe_ReloadCmd='systemctl reload nginx'\n" "$2" >"$1/$2.conf"
        touch "$1/$2.csr" "$1/$2.csr.conf"
    fi
}

calls() { cat "${temporaryDirectory}/calls.log" 2>/dev/null || true; }

unset ACME_HOME
export HOME="${temporaryDirectory}/home"
xrayTLSDirectory="${temporaryDirectory}/tls"
certbotLiveDirectory="${temporaryDirectory}/letsencrypt/live"
mkdir -p "${xrayTLSDirectory}"

# The empty ~/.acme.sh this installer creates, next to acme_manage.sh's
# acme.sh installed with --home and known only from its cron job.
installAcme "${HOME}/.acme.sh"
customHome="${temporaryDirectory}/opt/acme"
installAcme "${customHome}"
crontabLines="23 0 * * * \"${customHome}\"/acme.sh --cron --home \"${customHome}\" > /dev/null"
crontab() { [[ "$1" == "-l" ]] && printf '%s\n' "${crontabLines}"; }

# acme_manage.sh wildcard: example.com plus *.example.com, stored under example.com_ecc
issueCertificate "${customHome}/example.com_ecc" example.com "DNS:example.com,DNS:*.example.com"
# An RSA-style directory (no _ecc suffix) and a directory without a key
issueCertificate "${customHome}/blog.org" blog.org "DNS:blog.org"
mkdir -p "${customHome}/broken.net_ecc"
touch "${customHome}/broken.net_ecc/broken.net.conf" "${customHome}/broken.net_ecc/fullchain.cer"
# A certbot lineage, and the README certbot keeps next to them
issueCertificate "${certbotLiveDirectory}/certbot.net" certbot.net "DNS:certbot.net" fullchain.pem privkey.pem
touch "${certbotLiveDirectory}/README"

# --- host name matching -------------------------------------------------------
wildcardCert="${customHome}/example.com_ecc/fullchain.cer"
certificateCoversHost "${wildcardCert}" example.com || fail "apex must match"
certificateCoversHost "${wildcardCert}" vpn.example.com || fail "a subdomain must match the wildcard"
! certificateCoversHost "${wildcardCert}" a.b.example.com || fail "a wildcard covers one label only"
! certificateCoversHost "${wildcardCert}" other.org || fail "an unrelated name must not match (OpenSSL 3.0 exits 0 here)"

# --- discovery -----------------------------------------------------------------
[[ "$(detectLocalAcmeHomes)" == "${HOME}/.acme.sh
${customHome}" ]] || fail "acme.sh homes: $(detectLocalAcmeHomes)"
[[ "$(ACME_HOME="${customHome}/" detectLocalAcmeHomes)" == "${customHome}
${HOME}/.acme.sh" ]] || fail "\$ACME_HOME comes first and is listed once"

entries=$(localCertificateEntries)
expected="blog.org	RSA	${customHome}/blog.org/fullchain.cer	${customHome}/blog.org/blog.org.key	${customHome}
example.com	ECC	${wildcardCert}	${customHome}/example.com_ecc/example.com.key	${customHome}
certbot.net	certbot	${certbotLiveDirectory}/certbot.net/fullchain.pem	${certbotLiveDirectory}/certbot.net/privkey.pem	"
[[ "${entries}" == "${expected}" ]] || fail "unexpected certificate list:
${entries}"
[[ "$(describeCertificateEntry example.com ECC x y "${customHome}")" == "example.com [ECC] ${customHome}" \
    && "$(describeCertificateEntry a ECC x y "${HOME}/.acme.sh")" == "a [ECC]" \
    && "$(describeCertificateEntry certbot.net certbot x y "")" == "certbot.net [certbot]" ]] \
    || fail "certificate descriptions"

findLocalAcmeCertificateFor vpn.example.com || fail "the wildcard certificate covers vpn.example.com"
[[ "${acmeManagedSourceDomain}" == "example.com" && "${acmeManagedCertFile}" == "${wildcardCert}" \
    && "${acmeManagedHome}" == "${customHome}" && "${acmeManagedCertSelected}" == "true" ]] \
    || fail "auto-selection must record the wildcard certificate"
findLocalAcmeCertificateFor certbot.net && [[ -z "${acmeManagedHome}" ]] || fail "certbot certificates are found too"
acmeManagedCertSelected=
! findLocalAcmeCertificateFor other.org || fail "no certificate covers other.org"
[[ -z "${acmeManagedCertSelected}" ]] || fail "a failed lookup must not select a certificate"

# --- interactive selection -----------------------------------------------------
domain=
selectLocalAcmeCertificate < <(printf 'y\n2\nother.org\nvpn.example.com\n') >/dev/null \
    || fail "selection must retry until the certificate covers the domain"
[[ "${domain}" == "vpn.example.com" && "${acmeManagedSourceDomain}" == "example.com" ]] \
    || fail "selection picked ${acmeManagedSourceDomain} for ${domain}"
domain=
! selectLocalAcmeCertificate < <(printf 'y\n2\nother.org\nq\n') >/dev/null || fail "q must cancel the selection"
! selectLocalAcmeCertificate < <(printf 'y\n2\nother.org\n') >/dev/null || fail "end of input must cancel, not ask forever"
domain=vpn.example.com
selectLocalAcmeCertificate < <(printf 'y\n2\nvpn.example.com\n') >/dev/null || fail "selection failed"

# --- deploy --------------------------------------------------------------------
acmeConfBefore=$(cat "${customHome}/example.com_ecc/example.com.conf")
deployLocalAcmeCertificate || fail "deploy failed"
cmp -s "${wildcardCert}" "${xrayTLSDirectory}/vpn.example.com.crt" || fail "certificate not copied"
cmp -s "${customHome}/example.com_ecc/example.com.key" "${xrayTLSDirectory}/vpn.example.com.key" || fail "key not copied"
[[ "$(ls -l "${xrayTLSDirectory}/vpn.example.com.key" | cut -c1-10)" == "-rw-------" ]] || fail "the key must be private"
[[ "$(cat "${customHome}/example.com_ecc/example.com.conf")" == "${acmeConfBefore}" ]] \
    || fail "acme.sh's deploy target and reload command of another site must be kept"
[[ -z "$(calls)" ]] || fail "deploy must not call acme.sh"
[[ "$(acmeManagedSetting ACME_HOME)" == "${customHome}" && "$(acmeManagedSetting SERVICE_DOMAIN)" == "vpn.example.com" \
    && "$(acmeManagedSetting CERT_FILE)" == "${wildcardCert}" ]] || fail "acme_managed.conf not written"

# --- daily renewal sync --------------------------------------------------------
xrayActive=true
xrayRestarts=0
systemctl() { [[ "$1 $2" == "is-active --quiet" && "${xrayActive}" == "true" ]]; }
restartXray() { ((++xrayRestarts)); }

renewalTLS "" >/dev/null || fail "renewal without changes failed"
[[ "$(calls)" == "--cron --home ${customHome}" ]] || fail "renewal must run the registered acme.sh: $(calls)"
((xrayRestarts == 0)) || fail "an unchanged certificate must not restart Xray"

# acme.sh renewed the certificate (new key)
issueCertificate "${customHome}/example.com_ecc" example.com "DNS:example.com,DNS:*.example.com"
renewalTLS "" >/dev/null || fail "renewal with a new certificate failed"
cmp -s "${wildcardCert}" "${xrayTLSDirectory}/vpn.example.com.crt" || fail "renewed certificate not copied"
cmp -s "${customHome}/example.com_ecc/example.com.key" "${xrayTLSDirectory}/vpn.example.com.key" || fail "renewed key not copied"
((xrayRestarts == 1)) || fail "a renewed certificate must restart Xray once"

# A renewal caught half-way: new certificate, old key
deployedCert=$(cat "${xrayTLSDirectory}/vpn.example.com.crt")
cp "${customHome}/example.com_ecc/example.com.key" "${temporaryDirectory}/old.key"
issueCertificate "${customHome}/example.com_ecc" example.com "DNS:example.com,DNS:*.example.com"
cp "${temporaryDirectory}/old.key" "${customHome}/example.com_ecc/example.com.key"
! renewalTLS "" >/dev/null || fail "a key that does not match the certificate must be refused"
[[ "$(cat "${xrayTLSDirectory}/vpn.example.com.crt")" == "${deployedCert}" ]] || fail "the working certificate must be kept"
((xrayRestarts == 1)) || fail "a refused renewal must not restart Xray"

# Re-issued without the service name
issueCertificate "${customHome}/example.com_ecc" example.com "DNS:example.com"
! renewalTLS "" >/dev/null || fail "a certificate without vpn.example.com must be refused"

# Changed while Xray is stopped (e.g. during an install): no restart
issueCertificate "${customHome}/example.com_ecc" example.com "DNS:example.com,DNS:*.example.com"
xrayActive=false
renewalTLS "" >/dev/null || fail "renewal with Xray stopped failed"
((xrayRestarts == 1)) || fail "a stopped Xray must not be restarted"
xrayActive=true

# acme_managed.conf written by the previous version (no CERT_FILE/KEY_FILE)
printf 'ACME_HOME=%s\nSOURCE_DOMAIN=example.com\nSERVICE_DOMAIN=old.example.com\nECC=true\n' "${customHome}" \
    >"${xrayTLSDirectory}/acme_managed.conf"
renewalTLS "" >/dev/null || fail "renewal with an old acme_managed.conf failed"
cmp -s "${wildcardCert}" "${xrayTLSDirectory}/old.example.com.crt" || fail "old acme_managed.conf: certificate not synced"
((xrayRestarts == 2)) || fail "old acme_managed.conf: Xray not restarted"

# --- certbot -------------------------------------------------------------------
: >"${temporaryDirectory}/calls.log"
domain=
selectLocalAcmeCertificate < <(printf 'y\n3\n\n') >/dev/null || fail "certbot selection failed"
deployLocalAcmeCertificate || fail "certbot deploy failed"
[[ -z "$(acmeManagedSetting ACME_HOME)" ]] || fail "a certbot certificate has no acme.sh home"
cmp -s "${certbotLiveDirectory}/certbot.net/privkey.pem" "${xrayTLSDirectory}/certbot.net.key" || fail "certbot key not copied"
issueCertificate "${certbotLiveDirectory}/certbot.net" certbot.net "DNS:certbot.net" fullchain.pem privkey.pem
renewalTLS "" >/dev/null || fail "certbot renewal failed"
cmp -s "${certbotLiveDirectory}/certbot.net/fullchain.pem" "${xrayTLSDirectory}/certbot.net.crt" || fail "renewed certbot certificate not copied"
((xrayRestarts == 3)) || fail "a renewed certbot certificate must restart Xray"
[[ -z "$(calls)" ]] || fail "certbot certificates must not run acme.sh"

echo "acme certificate tests passed"
