# Where Xray reads its certificate and key.
xrayTLSDirectory=/opt/xray-agent/tls

# True when certificate file $1 is valid for host name $2. The printed result
# is used because "openssl x509 -checkhost" exits 0 on a mismatch with
# OpenSSL 3.0 (Debian 12, Ubuntu 22.04 and 24.04).
certificateCoversHost() {
    openssl x509 -in "$1" -noout -checkhost "$2" 2>/dev/null | grep -q " does match certificate"
}

# Read TLS certificate details
readAcmeTLS() {
    local readAcmeDomain=
    installedDNSAPIStatus=
    dnsTLSAcmeCertPath=
    if [[ -n "${currentHost}" ]]; then
        readAcmeDomain="${currentHost}"
    fi

    if [[ -n "${domain}" ]]; then
        readAcmeDomain="${domain}"
    fi

    dnsTLSDomain=$(echo "${readAcmeDomain}" | awk -F "." '{$1="";print $0}' | sed 's/^[[:space:]]*//' | sed 's/ /./g')
    [[ -z "${dnsTLSDomain}" || ! -d "$HOME/.acme.sh" ]] && return 0

    local candidateDir candidateCert candidateKey
    while IFS= read -r candidateDir; do
        while IFS= read -r candidateCert; do
            # Directory naming differs between acme.sh versions; rely on the certificate SAN.
            if openssl x509 -in "${candidateCert}" -noout -text 2>/dev/null | grep -Fq "DNS:*.${dnsTLSDomain}"; then
                candidateKey="${candidateCert%.cer}.key"
                if [[ ! -f "${candidateKey}" ]]; then
                    candidateKey=$(find "${candidateDir}" -maxdepth 1 -type f -name '*.key' -print -quit 2>/dev/null)
                fi
                if [[ -f "${candidateKey}" ]]; then
                    installedDNSAPIStatus=true
                    dnsTLSAcmeCertPath="${candidateCert}"
                    return 0
                fi
            fi
        done < <(find "${candidateDir}" -maxdepth 1 -type f -name '*.cer' 2>/dev/null)
    done < <(find "$HOME/.acme.sh" -maxdepth 1 -type d -name "*.${dnsTLSDomain}_ecc" 2>/dev/null)
}

# Custom email
customSSLEmail() {
    if echo "$1" | grep -q "validate email"; then
        read -r -p "是否重新输入邮箱地址[y/n]:" sslEmailStatus
        if [[ "${sslEmailStatus}" == "y" ]]; then
            sed '/ACCOUNT_EMAIL/d' /root/.acme.sh/account.conf >/root/.acme.sh/account.conf_tmp && mv /root/.acme.sh/account.conf_tmp /root/.acme.sh/account.conf
        else
            exit 0
        fi
    fi

    if [[ -d "/root/.acme.sh" && -f "/root/.acme.sh/account.conf" ]]; then
        if ! grep -q "ACCOUNT_EMAIL" <"/root/.acme.sh/account.conf" && ! echo "${sslType}" | grep -q "letsencrypt"; then
            read -r -p "请输入邮箱地址:" sslEmail
            if echo "${sslEmail}" | grep -q "@"; then
                echo "ACCOUNT_EMAIL='${sslEmail}'" >>/root/.acme.sh/account.conf
                echoContent green " ---> 添加完毕"
            else
                echoContent yellow "请重新输入正确的邮箱格式[例: username@example.com]"
                customSSLEmail
            fi
        fi
    fi

}

# Where certbot keeps the current certificate of each lineage.
certbotLiveDirectory=/etc/letsencrypt/live

# Every acme.sh home on this host, one per line: $ACME_HOME, the default
# homes, the homes named by acme.sh cron jobs (installed with --home) and an
# acme.sh on PATH. All are listed, because the installer itself creates
# ~/.acme.sh next to a custom home.
detectLocalAcmeHomes() {
    local candidate resolved seen=
    {
        printf '%s\n' "${ACME_HOME:-}" "$HOME/.acme.sh" /root/.acme.sh
        crontab -l 2>/dev/null | grep -- '--cron' \
            | sed -n 's/.*--home[[:space:]]\{1,\}"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p'
        if command -v acme.sh >/dev/null 2>&1; then
            dirname "$(readlink -f "$(command -v acme.sh)")"
        fi
    } | while IFS= read -r candidate; do
        [[ -n "${candidate}" && -x "${candidate}/acme.sh" ]] || continue
        resolved=$(readlink -f "${candidate}" 2>/dev/null || echo "${candidate}")
        [[ "${seen}" == *$'\n'"${resolved}"$'\n'* ]] && continue
        seen+=$'\n'"${resolved}"$'\n'
        echo "${resolved}"
    done
}

# Certificates issued on this host, one per line as
# "<name>\t<kind>\t<certificate>\t<key>\t<acme home>"; kind is ECC or RSA for
# acme.sh and certbot for certbot (no acme home). acme.sh keeps ECC
# certificates in <domain>_ecc and RSA ones in <domain>; a certificate for
# several names (acme_manage.sh: example.com plus *.example.com) lives under
# the first one.
localCertificateEntries() {
    local acmeHome conf certDir certDomain kind
    while IFS= read -r acmeHome; do
        while read -r conf; do
            certDir=$(dirname "${conf}")
            certDomain=$(basename "${conf}" .conf)
            # Also skips <domain>.csr.conf
            [[ -f "${certDir}/fullchain.cer" && -f "${certDir}/${certDomain}.key" ]] || continue
            kind=RSA
            [[ "$(basename "${certDir}")" == *_ecc ]] && kind=ECC
            printf '%s\t%s\t%s\t%s\t%s\n' "${certDomain}" "${kind}" "${certDir}/fullchain.cer" "${certDir}/${certDomain}.key" "${acmeHome}"
        done < <(find "${acmeHome}" -mindepth 2 -maxdepth 2 -type f -name '*.conf' 2>/dev/null | sort)
    done < <(detectLocalAcmeHomes)

    for certDir in "${certbotLiveDirectory}"/*/; do
        certDir=${certDir%/}
        [[ -s "${certDir}/fullchain.pem" && -s "${certDir}/privkey.pem" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "${certDir}")" certbot "${certDir}/fullchain.pem" "${certDir}/privkey.pem" ""
    done
}

# Record entry fields $1-$5 (see localCertificateEntries) as the certificate to use.
setManagedCertificate() {
    acmeManagedSourceDomain=$1
    acmeManagedCertFile=$3
    acmeManagedKeyFile=$4
    acmeManagedHome=$5
    acmeManagedCertSelected=true
}

# Select an unexpired certificate that covers domain $1, as
# selectLocalAcmeCertificate does. Used when the domain was typed in instead
# of picked from the list.
findLocalAcmeCertificateFor() {
    local name kind certFile keyFile acmeHome
    while IFS=$'\t' read -r name kind certFile keyFile acmeHome; do
        openssl x509 -in "${certFile}" -noout -checkend 0 >/dev/null 2>&1 || continue
        certificateCoversHost "${certFile}" "$1" || continue
        setManagedCertificate "${name}" "${kind}" "${certFile}" "${keyFile}" "${acmeHome}"
        return 0
    done < <(localCertificateEntries)
    return 1
}

# "<name> [<kind>]", plus the acme.sh home when it is not the default one.
describeCertificateEntry() {
    local description="$1 [$2]"
    [[ -n "$5" && "$5" != "$(readlink -f "$HOME/.acme.sh" 2>/dev/null)" ]] && description+=" ${5}"
    echo "${description}"
}

# Choose one of the certificates issued on this host (acme.sh or certbot).
selectLocalAcmeCertificate() {
    local -a entries=()
    local entry
    while IFS= read -r entry; do
        entries+=("${entry}")
    done < <(localCertificateEntries)
    ((${#entries[@]} > 0)) || return 1

    local i name kind certFile keyFile acmeHome
    echoContent skyBlue "\n---------- 本机已签发证书 (acme.sh / certbot) ----------"
    for i in "${!entries[@]}"; do
        IFS=$'\t' read -r name kind certFile keyFile acmeHome <<<"${entries[$i]}"
        echoContent yellow "$((i + 1)). $(describeCertificateEntry "${name}" "${kind}" "${certFile}" "${keyFile}" "${acmeHome}")"
    done
    echoContent skyBlue "--------------------------------------------------------"
    read -r -p "是否使用以上证书？[y/n]:" useAcmeManagedCert
    [[ "${useAcmeManagedCert}" == "y" ]] || return 1

    local selectedIndex=
    read -r -p "请选择证书编号:" selectedIndex
    if [[ ! "${selectedIndex}" =~ ^[0-9]+$ ]] || ((selectedIndex < 1 || selectedIndex > ${#entries[@]})); then
        echoContent red " ---> 证书编号无效"
        return 1
    fi
    IFS=$'\t' read -r name kind certFile keyFile acmeHome <<<"${entries[$((selectedIndex - 1))]}"

    local serviceDomain=
    read -r -p "请输入 Xray 使用的域名[默认:${name}，通配符证书可填子域名]:" serviceDomain
    serviceDomain=${serviceDomain:-${name}}

    while ! certificateCoversHost "${certFile}" "${serviceDomain}"; do
        echoContent red " ---> 所选证书不包含域名 ${serviceDomain}"
        # End of input cancels too, instead of asking forever
        read -r -p "请重新输入证书覆盖的域名，输入 q 取消:" serviceDomain || return 1
        [[ "${serviceDomain}" == "q" ]] && return 1
    done

    setManagedCertificate "${name}" "${kind}" "${certFile}" "${keyFile}" "${acmeHome}"
    domain=${serviceDomain}
    echoContent green " ---> 已选择 ${name} 证书，Xray域名: ${domain}"
    return 0
}

# Value of key $1 in acme_managed.conf (written by deployLocalAcmeCertificate).
acmeManagedSetting() {
    awk -v key="$1" 'index($0, key "=") == 1 {print substr($0, length(key) + 2); exit}' \
        "${xrayTLSDirectory}/acme_managed.conf" 2>/dev/null
}

# Copy certificate $1 and key $2 to the files Xray reads for domain $3,
# unless they are already identical. Sets acmeManagedCertChanged=true when
# the files were replaced.
syncAcmeManagedCertificate() {
    local sourceCert=$1 sourceKey=$2 serviceDomain=$3
    local certFile="${xrayTLSDirectory}/${serviceDomain}.crt" keyFile="${xrayTLSDirectory}/${serviceDomain}.key"
    acmeManagedCertChanged=

    if [[ ! -s "${sourceCert}" || ! -s "${sourceKey}" ]]; then
        echoContent red " ---> 找不到证书: ${sourceCert}"
        return 1
    fi
    cmp -s "${sourceCert}" "${certFile}" && cmp -s "${sourceKey}" "${keyFile}" && return 0

    # Refuse a renewal caught half-way or a certificate re-issued without this name.
    if ! certificateCoversHost "${sourceCert}" "${serviceDomain}" \
        || [[ "$(openssl x509 -in "${sourceCert}" -noout -pubkey 2>/dev/null)" != "$(openssl pkey -in "${sourceKey}" -pubout 2>/dev/null)" ]]; then
        echoContent red " ---> 证书不包含 ${serviceDomain} 或与私钥不匹配，保留现有证书"
        return 1
    fi

    mkdir -p "${xrayTLSDirectory}"
    if ! (umask 077 && cp "${sourceKey}" "${keyFile}.tmp") || ! cp "${sourceCert}" "${certFile}.tmp" \
        || ! mv -f "${keyFile}.tmp" "${keyFile}" || ! mv -f "${certFile}.tmp" "${certFile}"; then
        rm -f "${keyFile}.tmp" "${certFile}.tmp"
        echoContent red " ---> 复制证书失败"
        return 1
    fi
    acmeManagedCertChanged=true
}

# Use the selected certificate: copy it for Xray and record it in
# acme_managed.conf, from which the daily RenewTLS job copies renewed
# certificates. The issuing client's own settings are not touched: acme.sh's
# "--install-cert" keeps a single deploy target per certificate, so it would
# take over (and an uninstall would break) the target and reload command of
# another site using the same certificate.
deployLocalAcmeCertificate() {
    if ! syncAcmeManagedCertificate "${acmeManagedCertFile}" "${acmeManagedKeyFile}" "${domain}"; then
        echoContent red " ---> 部署证书失败"
        return 1
    fi
    cat <<EOF >"${xrayTLSDirectory}/acme_managed.conf"
ACME_HOME=${acmeManagedHome}
SOURCE_DOMAIN=${acmeManagedSourceDomain}
SERVICE_DOMAIN=${domain}
CERT_FILE=${acmeManagedCertFile}
KEY_FILE=${acmeManagedKeyFile}
EOF
    local client=acme.sh
    [[ -z "${acmeManagedHome}" ]] && client=certbot
    echoContent green " ---> 已复制证书到 ${xrayTLSDirectory}/${domain}.crt"
    echoContent green " ---> ${client} 续期后，每日定时任务会同步新证书并重启 Xray"
}

# List the certificates issued on this host.
listLocalAcmeCertificates() {
    local name kind certFile keyFile acmeHome
    echoContent skyBlue "\n---------- 本机已签发证书 ----------"
    while IFS=$'\t' read -r name kind certFile keyFile acmeHome; do
        echoContent yellow " - $(describeCertificateEntry "${name}" "${kind}" "${certFile}" "${keyFile}" "${acmeHome}")"
    done < <(localCertificateEntries)
    echoContent skyBlue "------------------------------------"
}

# Choose the SSL installation type
switchSSLType() {
    if [[ -z "${sslType}" ]]; then
        echoContent red "\n=============================================================="
        echoContent skyBlue "请选择 SSL 证书提供商"
        echoContent red "=============================================================="
        echoContent yellow "1. Let's Encrypt [推荐，默认]"
        echoContent green "   - 免费、稳定、广泛使用"
        echoContent yellow "2. Google Trust Services (GTS)"
        echoContent green "   - 需要 EAB 凭证 (External Account Binding)"
        echoContent red "=============================================================="
        read -r -p "请选择 [1-2，回车默认使用 Let's Encrypt]:" selectSSLType
        case ${selectSSLType} in
            2)
                sslType="google"
                echoContent green "\n ---> 已选择: Google Trust Services (GTS)"
                echoContent red "\n=============================================================="
                echoContent skyBlue "⚠️  GTS 需要 External Account Binding (EAB) 凭证"
                echoContent red "=============================================================="
                read -r -p "请输入 EAB Key ID (KID): " googleEabKid
                read -r -p "请输入 EAB HMAC Key: " googleEabHmac
                if [[ -z "${googleEabKid}" || -z "${googleEabHmac}" ]]; then
                    echoContent red "\n ---> EAB 凭证不能为空，退出安装"
                    echoContent yellow " ---> 建议使用 Let's Encrypt (无需额外注册)"
                    exit 0
                fi
                echo "${googleEabKid}" >/opt/xray-agent/tls/google_eab_kid
                echo "${googleEabHmac}" >/opt/xray-agent/tls/google_eab_hmac
                echoContent green "\n ---> EAB 凭证已保存"
                ;;
            *)
                sslType="letsencrypt"
                echoContent green "\n ---> 已选择: Let's Encrypt (默认)"
                ;;
        esac
        echo "${sslType}" >/opt/xray-agent/tls/ssl_type
    fi
}

# Choose how ACME issues the certificate
selectAcmeInstallSSL() {
    if [[ "${ipType}" == "6" ]]; then
        sslIPv6="--listen-v6"
    fi

    acmeInstallSSL

    readAcmeTLS
}

# Install the SSL certificate
acmeInstallSSL() {
    # Google GTS requires registering an EAB account first
    if [[ "${sslType}" == "google" ]]; then
        local googleEabKid=""
        local googleEabHmac=""

        # Read the saved EAB credentials
        if [[ -f /opt/xray-agent/tls/google_eab_kid ]]; then
            googleEabKid=$(cat /opt/xray-agent/tls/google_eab_kid)
            googleEabHmac=$(cat /opt/xray-agent/tls/google_eab_hmac)
        fi

        if [[ -n "${googleEabKid}" && -n "${googleEabHmac}" ]]; then
            echoContent skyBlue " ---> 检测到 Google EAB 凭证，正在注册账号..."

            # Register a Google GTS account
            if ! "$HOME/.acme.sh/acme.sh" --register-account \
                --server google \
                --eab-kid "${googleEabKid}" \
                --eab-hmac-key "${googleEabHmac}" 2>&1 | tee -a /opt/xray-agent/tls/acme.log; then

                echoContent red "\n ---> Google GTS 账号注册失败"
                echoContent yellow " ---> 请检查 EAB 凭证是否正确"
                echoContent yellow " ---> 或选择其他证书提供商 (Let's Encrypt)"
                exit 0
            fi

            echoContent green " ---> Google GTS 账号注册成功"
        fi
    fi

    echoContent green " ---> 生成证书中"

    # Standalone mode needs Nginx stopped to free port 80
    handleNginx stop

    sudo "$HOME/.acme.sh/acme.sh" --issue -d "${tlsDomain}" --standalone -k ec-256 --server "${sslType}" ${sslIPv6} 2>&1 | tee -a /opt/xray-agent/tls/acme.log >/dev/null

    # Restart Nginx after the certificate is issued
    handleNginx start
}

# Install TLS
installTLS() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : 申请TLS证书\n"

    readAcmeTLS
    local tlsDomain=${domain}

    if [[ "${acmeManagedCertSelected}" == "true" ]]; then
        echoContent green " ---> 使用本机已签发的证书: ${acmeManagedSourceDomain}"
        if ! deployLocalAcmeCertificate; then
            exit 1
        fi
        return 0
    fi

    if [[ -d "$HOME/.acme.sh" ]]; then
        listLocalAcmeCertificates
    fi

    # Install TLS
    if [[ -f "/opt/xray-agent/tls/${tlsDomain}.crt" && -f "/opt/xray-agent/tls/${tlsDomain}.key" && -n $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]] || [[ -d "$HOME/.acme.sh/${tlsDomain}_ecc" && -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.key" && -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.cer" ]] || [[ "${installedDNSAPIStatus}" == "true" ]]; then
        echoContent green " ---> 检测到证书"
        renewalTLS

        if [[ -z $(find /opt/xray-agent/tls/ -name "${tlsDomain}.crt") ]] || [[ -z $(find /opt/xray-agent/tls/ -name "${tlsDomain}.key") ]] || [[ -z $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]]; then
            if [[ "${installedDNSAPIStatus}" == "true" ]]; then
                sudo "$HOME/.acme.sh/acme.sh" --installcert -d "*.${dnsTLSDomain}" --fullchain-file "/opt/xray-agent/tls/${tlsDomain}.crt" --key-file "/opt/xray-agent/tls/${tlsDomain}.key" --ecc >/dev/null
            else
                sudo "$HOME/.acme.sh/acme.sh" --installcert -d "${tlsDomain}" --fullchain-file "/opt/xray-agent/tls/${tlsDomain}.crt" --key-file "/opt/xray-agent/tls/${tlsDomain}.key" --ecc >/dev/null
            fi

        else
            if [[ -d "$HOME/.acme.sh/${tlsDomain}_ecc" && -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.key" && -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.cer" ]] || [[ "${installedDNSAPIStatus}" == "true" ]]; then
                if [[ -z "${lastInstallationConfig}" ]]; then
                    echoContent yellow " ---> 如未过期或者自定义证书请选择[n]\n"
                    read -r -p "是否重新安装？[y/n]:" reInstallStatus
                    if [[ "${reInstallStatus}" == "y" ]]; then
                        rm -rf /opt/xray-agent/tls/*
                        installTLS "$1"
                    fi
                fi
            fi
        fi

    elif [[ -d "$HOME/.acme.sh" ]] && [[ ! -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.cer" || ! -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.key" ]]; then
        # The domain was typed in rather than picked from the list: an
        # existing certificate covering it (e.g. example.com plus
        # *.example.com) is used instead of issuing a new one.
        if findLocalAcmeCertificateFor "${tlsDomain}"; then
            echoContent green " ---> 检测到覆盖 ${tlsDomain} 的已签发证书: ${acmeManagedSourceDomain}"
            deployLocalAcmeCertificate || exit 1
            return 0
        fi
        local -a localAcmeDirs=()
        mapfile -t localAcmeDirs < <(find "$HOME/.acme.sh" -maxdepth 1 -type d -name "*_ecc" 2>/dev/null)
        if ((${#localAcmeDirs[@]} > 0)); then
            echoContent red " ---> 未检测到 ${tlsDomain} 或 *.${dnsTLSDomain} 证书，脚本不会代为申请"
            echoContent yellow " ---> 请使用本地 acme.sh 或面板自行申请后再次运行"
            exit 0
        fi

        echoContent green " ---> 本地 acme.sh 尚无证书，开始申请"
        echoContent green " ---> 申请过程需要开放 80 端口"
        allowPort 80

        switchSSLType
        customSSLEmail
        selectAcmeInstallSSL

        sudo "$HOME/.acme.sh/acme.sh" --installcert -d "${tlsDomain}" --fullchainpath "/opt/xray-agent/tls/${tlsDomain}.crt" --keypath "/opt/xray-agent/tls/${tlsDomain}.key" --ecc >/dev/null

        if [[ ! -f "/opt/xray-agent/tls/${tlsDomain}.crt" || ! -f "/opt/xray-agent/tls/${tlsDomain}.key" ]] || [[ -z $(cat "/opt/xray-agent/tls/${tlsDomain}.key") || -z $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]]; then
            tail -n 10 /opt/xray-agent/tls/acme.log
            if [[ ${installTLSCount} == "1" ]]; then
                echoContent red " ---> TLS安装失败，请检查acme日志"
                exit 0
            fi

            echo

            if tail -n 10 /opt/xray-agent/tls/acme.log | grep -q "Could not validate email address as valid"; then
                echoContent red " ---> 邮箱无法通过SSL厂商验证，请重新输入"
                echo
                customSSLEmail "validate email"
                installTLSCount=1
                installTLS "$1"
            else
                installTLSCount=1
                installTLS "$1"
            fi
        fi

        echoContent green " ---> TLS生成成功"
    else
        echoContent yellow " ---> 未安装acme.sh"
        exit 0
    fi
}

# Cron job to renew the TLS certificate
installCronTLS() {
    if [[ -z "${btDomain}" ]]; then
        echoContent skyBlue "\n进度 $1/${totalProgress} : 添加定时维护证书"
        if [[ "${acmeManagedCertSelected}" == "true" || -f "${xrayTLSDirectory}/acme_managed.conf" ]]; then
            echoContent green " ---> 证书由 acme.sh / certbot 续期，定时任务每日同步新证书并重启 Xray"
        fi
        crontab -l >/opt/xray-agent/backup_crontab.cron 2>/dev/null || true
        local historyCrontab
        historyCrontab=$(sed '/xray-agent-renew-tls/d;/xray-agent\/install.sh RenewTLS/d' /opt/xray-agent/backup_crontab.cron)
        echo "${historyCrontab}" >/opt/xray-agent/backup_crontab.cron
        echo "30 1 * * * /bin/bash /opt/xray-agent/install.sh RenewTLS >> /opt/xray-agent/crontab_tls.log 2>&1 # xray-agent-renew-tls" >>/opt/xray-agent/backup_crontab.cron
        crontab /opt/xray-agent/backup_crontab.cron
        echoContent green "\n ---> 添加定时维护证书成功"
    fi
}

# Renew the certificate
renewalTLS() {

    if [[ -n $1 ]]; then
        echoContent skyBlue "\n进度  $1/1 : 更新证书"
    fi

    if [[ -f "${xrayTLSDirectory}/acme_managed.conf" ]]; then
        local managedAcmeHome managedCertFile managedKeyFile managedSourceDirectory
        managedAcmeHome=$(acmeManagedSetting ACME_HOME)
        managedCertFile=$(acmeManagedSetting CERT_FILE)
        managedKeyFile=$(acmeManagedSetting KEY_FILE)
        if [[ -z "${managedCertFile}" ]]; then
            # Written before CERT_FILE existed: always acme.sh
            managedSourceDirectory="${managedAcmeHome}/$(acmeManagedSetting SOURCE_DOMAIN)"
            [[ "$(acmeManagedSetting ECC)" == "true" ]] && managedSourceDirectory+="_ecc"
            managedCertFile="${managedSourceDirectory}/fullchain.cer"
            managedKeyFile="${managedSourceDirectory}/$(acmeManagedSetting SOURCE_DOMAIN).key"
        fi
        if [[ -z "${managedAcmeHome}" ]]; then
            echoContent green " ---> 证书由 certbot 自动续期，检查是否有新证书"
        elif [[ -x "${managedAcmeHome}/acme.sh" ]]; then
            echoContent green " ---> 使用 acme.sh 原有配置检查并续期证书"
            "${managedAcmeHome}/acme.sh" --cron --home "${managedAcmeHome}"
        else
            echoContent red " ---> 找不到已登记的 acme.sh: ${managedAcmeHome}/acme.sh"
            return 1
        fi
        syncAcmeManagedCertificate "${managedCertFile}" "${managedKeyFile}" "$(acmeManagedSetting SERVICE_DOMAIN)" || return 1
        # Only a running Xray is restarted; an install starts it after writing its config.
        if [[ "${acmeManagedCertChanged}" == "true" ]] && systemctl is-active --quiet xray.service 2>/dev/null; then
            echoContent green " ---> 证书已更新，重启 Xray"
            restartXray || return 1
        fi
        echoContent green " ---> 证书维护完成"
        return 0
    fi

    readAcmeTLS
    local domain=${currentHost}
    if [[ -z "${currentHost}" && -n "${tlsDomain}" ]]; then
        domain=${tlsDomain}
    fi

    if [[ -d "$HOME/.acme.sh/${domain}_ecc" && -f "$HOME/.acme.sh/${domain}_ecc/${domain}.key" && -f "$HOME/.acme.sh/${domain}_ecc/${domain}.cer" ]] || [[ "${installedDNSAPIStatus}" == "true" ]]; then
        modifyTime=

        if [[ "${installedDNSAPIStatus}" == "true" ]]; then
            modifyTime=$(stat --format=%z "${dnsTLSAcmeCertPath}")
        else
            modifyTime=$(stat --format=%z "$HOME/.acme.sh/${domain}_ecc/${domain}.cer")
        fi

        modifyTime=$(date +%s -d "${modifyTime}")
        currentTime=$(date +%s)
        ((stampDiff = currentTime - modifyTime))
        ((days = stampDiff / 86400))
        ((remainingDays = sslRenewalDays - days))

        tlsStatus=${remainingDays}
        if [[ ${remainingDays} -le 0 ]]; then
            tlsStatus="已过期"
        fi

        echoContent skyBlue " ---> 证书检查日期:$(date "+%F %H:%M:%S")"
        echoContent skyBlue " ---> 证书生成日期:$(date -d @"${modifyTime}" +"%F %H:%M:%S")"
        echoContent skyBlue " ---> 证书生成天数:${days}"
        echoContent skyBlue " ---> 证书剩余天数:"${tlsStatus}
        echoContent skyBlue " ---> 证书过期前最后一天自动更新，如更新失败请手动更新"

        if [[ ${remainingDays} -le 1 ]]; then
            echoContent yellow " ---> 重新生成证书"
            handleNginx stop || return 1

            if [[ "${coreInstallType}" == "1" ]]; then
                handleXray stop
            fi

            sudo "$HOME/.acme.sh/acme.sh" --cron --home "$HOME/.acme.sh"
            local renewalDomain="${domain}"
            if [[ "${installedDNSAPIStatus}" == "true" ]]; then
                renewalDomain="*.${dnsTLSDomain}"
            fi
            sudo "$HOME/.acme.sh/acme.sh" --install-cert -d "${renewalDomain}" --fullchain-file "/opt/xray-agent/tls/${domain}.crt" --key-file "/opt/xray-agent/tls/${domain}.key" --ecc
            # Start nginx regardless of the Xray result so the fallback site,
            # subscriptions and WS paths are not left down overnight.
            local restartStatus=0
            restartXray || restartStatus=$?
            handleNginx start
            return "${restartStatus}"
        else
            echoContent green " ---> 证书有效"
        fi
    elif [[ -f "/opt/xray-agent/tls/${tlsDomain}.crt" && -f "/opt/xray-agent/tls/${tlsDomain}.key" && -n $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]]; then
        echoContent yellow " ---> 检测到使用自定义证书，无法执行renew操作。"
    else
        echoContent red " ---> 未安装"
    fi
}
