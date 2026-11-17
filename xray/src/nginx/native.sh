# Install nginx from the nginx.org stable repository (Debian/Ubuntu). The
# signing key is fetched before the repository is added, so a failed download
# does not leave an unsigned source behind that breaks later apt updates.
installNginxTools() {
    local installLog=/opt/xray-agent/install.log
    if [[ "${release}" == "debian" || "${release}" == "ubuntu" ]]; then
        apt install gnupg2 ca-certificates lsb-release -y >>"${installLog}" 2>&1
        if ! downloadFile "https://nginx.org/keys/nginx_signing.key" "/tmp/nginx_signing.key"; then
            echoContent red " ---> 下载 nginx.org 签名密钥失败，请检查网络后重试"
            return 1
        fi
        sudo mv /tmp/nginx_signing.key /etc/apt/trusted.gpg.d/nginx_signing.asc
        # Use the stable release instead of mainline
        echo "deb http://nginx.org/packages/${release} $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list >/dev/null
        echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | sudo tee /etc/apt/preferences.d/99nginx >/dev/null
        apt update >>"${installLog}" 2>&1
    fi
    ${installType} nginx >>"${installLog}" 2>&1
    if ! command -v nginx >/dev/null 2>&1; then
        echoContent red " ---> Nginx 安装失败，安装日志: ${installLog}"
        tail -n 20 "${installLog}"
        return 1
    fi
    echoContent green " ---> 已安装 $(nginx -v 2>&1 | sed 's/^nginx version: //')"
    bootStartup nginx || echoContent yellow " ---> 无法设置 Nginx 开机自启，请手动执行 systemctl enable nginx"
}

# Remove the default nginx config
removeNginxDefaultConf() {
    if [[ -f ${nginxConfigPath}default.conf ]]; then
        if [[ "$(grep -c "server_name" <${nginxConfigPath}default.conf)" == "1" ]] && [[ "$(grep -c "server_name  localhost;" <${nginxConfigPath}default.conf)" == "1" ]]; then
            echoContent green " ---> 删除Nginx默认配置"
            rm -rf ${nginxConfigPath}default.conf >/dev/null 2>&1
        fi
    fi
}
