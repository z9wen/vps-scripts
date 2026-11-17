# Archive URL of decoy site number $1 (menu order, see nginxTemplates).
nginxTemplateArchive() {
    local number=$1
    [[ "${number}" =~ ^[0-9]+$ ]] && ((number >= 1 && number <= ${#nginxTemplates[@]})) || return 1
    echo "${decoySiteBase}/${nginxTemplates[number - 1]#*|}.zip"
}

deployNginxTemplate() {
    local templateNumber=$1 url site stagingDir archive siteRoot backupDir
    [[ -n "${nginxStaticPath}" && "${nginxStaticPath}" != "/" ]] || return 1
    url=$(nginxTemplateArchive "${templateNumber}") || return 1
    site=${nginxTemplates[templateNumber - 1]#*|}
    stagingDir=$(mktemp -d /tmp/xray-agent-site.XXXXXX) || return 1
    archive="${stagingDir}/site.zip"

    if ! downloadFile "${url}" "${archive}" --https-only || ! unzip -tq "${archive}" >/dev/null 2>&1; then
        rm -rf "${stagingDir}"
        echoContent red " ---> 伪装站下载或压缩包校验失败，保留现有站点"
        return 1
    fi
    siteRoot="${stagingDir}/content"
    unzip -oq "${archive}" -d "${siteRoot}" || {
        rm -rf "${stagingDir}"
        return 1
    }
    rm -f "${archive}"
    [[ -f "${siteRoot}/index.html" ]] || {
        rm -rf "${stagingDir}"
        echoContent red " ---> 伪装站压缩包内容不完整，保留现有站点"
        return 1
    }
    decoyPrepareSite "${siteRoot}" "${site}"
    # Marks the directory as our decoy (reinstall prompt, uninstall); nginx
    # answers /check with 404, so it does not identify this script.
    : >"${siteRoot}/check"

    mkdir -p "${nginxStaticPath}"
    backupDir=$(mktemp -d /tmp/xray-agent-site-backup.XXXXXX) || {
        rm -rf "${stagingDir}"
        return 1
    }
    cp -a "${nginxStaticPath}/." "${backupDir}/" 2>/dev/null || true
    find "${nginxStaticPath}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    if ! cp -a "${siteRoot}/." "${nginxStaticPath}/"; then
        find "${nginxStaticPath}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        cp -a "${backupDir}/." "${nginxStaticPath}/" 2>/dev/null || true
        rm -rf "${stagingDir}" "${backupDir}"
        echoContent red " ---> 伪装站部署失败，已恢复原站点"
        return 1
    fi
    rm -rf "${stagingDir}" "${backupDir}"
}
# Nginx masquerade blog
nginxBlog() {
    if [[ -n "$1" ]]; then
        echoContent skyBlue "\n进度 $1/${totalProgress} : 添加伪装站点"
    else
        echoContent yellow "\n开始添加伪装站点"
    fi

    if [[ -d "${nginxStaticPath}" && -f "${nginxStaticPath}/check" ]]; then
        echo
        if [[ -z "${lastInstallationConfig}" ]]; then
            read -r -p "检测到安装伪装站点，是否需要重新安装[y/n]:" nginxBlogInstallStatus
        else
            nginxBlogInstallStatus="n"
        fi

        if [[ "${nginxBlogInstallStatus}" == "y" ]]; then
            randomNum=$(randomNum 1 "${#nginxTemplates[@]}")
            deployNginxTemplate "${randomNum}" || return 1
            echoContent green " ---> 添加伪装站点成功"
        fi
    else
        randomNum=$(randomNum 1 "${#nginxTemplates[@]}")
        deployNginxTemplate "${randomNum}" || return 1
        echoContent green " ---> 添加伪装站点成功"
    fi

}

# Remove the nginx 302 config
removeNginx302() {
    # Check that the config file exists
    if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
        echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
        echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
        return 1
    fi

    # Use a temp file to avoid modifying the original file inside the loop
    local tmpFile="${nginxConfigPath}xray-agent.conf.tmp"
    cp "${nginxConfigPath}xray-agent.conf" "${tmpFile}"

    # Delete all return 302/301 lines (excluding those containing request_uri)
    sed -i '/return 30[12]/!b; /request_uri/b; d' "${tmpFile}"

    # Replace the original file
    mv "${tmpFile}" "${nginxConfigPath}xray-agent.conf"
}

# Check whether the 302 redirect succeeded
checkNginx302() {
    local testHost="${currentHost}"
    local testPort="${currentPort}"

    if [[ -z "${testHost}" || "${testHost}" == "null" ]]; then
        testHost=$(getPublicIP)
    fi
    if [[ -z "${testHost}" ]]; then
        testHost="127.0.0.1"
    fi

    if [[ -z "${testPort}" || "${testPort}" == "null" ]]; then
        if [[ -n "${currentDefaultPort}" ]]; then
            testPort="${currentDefaultPort}"
        else
            testPort=443
        fi
    fi

    local scheme="https"
    if [[ "${testPort}" == "80" ]]; then
        scheme="http"
    fi

    local targetUrl="${scheme}://${testHost}:${testPort}"
    local httpCode=
    httpCode=$(curl -I -k --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "${targetUrl}")

    if [[ "${httpCode}" == "302" ]]; then
        echoContent green " ---> 重定向设置完毕 (HTTP ${httpCode})"
        exit 0
    fi

    echoContent red " ---> 重定向设置失败，HTTP状态码: ${httpCode}"
    echoContent yellow " ---> 检测 URL: ${targetUrl}"
    echoContent yellow "请检查配置是否正确"
    backupNginxConfig restoreBackup
    handleNginx stop >/dev/null 2>&1
    handleNginx start >/dev/null 2>&1
}

# Back up/restore the nginx file
backupNginxConfig() {
    if [[ "$1" == "backup" ]]; then
        if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
            echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
            echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
            return 1
        fi
        cp ${nginxConfigPath}xray-agent.conf /opt/xray-agent/xray-agent_backup.conf
        echoContent green " ---> nginx配置文件备份成功"
    fi

    if [[ "$1" == "restoreBackup" ]] && [[ -f "/opt/xray-agent/xray-agent_backup.conf" ]]; then
        cp /opt/xray-agent/xray-agent_backup.conf ${nginxConfigPath}xray-agent.conf
        echoContent green " ---> nginx配置文件恢复备份成功"
        rm /opt/xray-agent/xray-agent_backup.conf
    fi

}
# Add the 302 config
addNginx302() {
    local redirectUrl="$1"
    local redirectCode="302" # Always use 302

    # Check that the config file exists
    if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
        echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
        echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
        backupNginxConfig restoreBackup
        return 1
    fi

    # Validate the URL format
    if [[ ! "${redirectUrl}" =~ ^https?:// ]]; then
        echoContent red " ---> URL 格式错误，必须以 http:// 或 https:// 开头"
        backupNginxConfig restoreBackup
        return 1
    fi

    # Escape special characters (single quotes)
    redirectUrl="${redirectUrl//\'/\'\\\'\'}"

    # Read the line numbers of all `location / {` into an array
    local lineNumbers=()
    while IFS= read -r line; do
        lineNumbers+=("$(echo "${line}" | awk -F ":" '{print $1}')")
    done < <(grep -n "location / {" "${nginxConfigPath}xray-agent.conf")

    # Insert from back to front so line numbers do not shift
    local count=${#lineNumbers[@]}
    for ((i = count - 1; i >= 0; i--)); do
        local insertIndex=$((lineNumbers[i] + 1))
        sed -i "${insertIndex}i\\        return ${redirectCode} '${redirectUrl}';" "${nginxConfigPath}xray-agent.conf"
    done

    if [[ ${count} -eq 0 ]]; then
        echoContent red " ---> 重定向添加失败：未找到 location / { 配置"
        backupNginxConfig restoreBackup
        return 1
    fi

    echoContent green " ---> 已在 ${count} 处添加 ${redirectCode} 重定向"
}

# Update the masquerade site
updateNginxBlog() {
    echoContent skyBlue "\n进度 $1/${totalProgress} : 更换伪装站点"

    if ! echo "${currentInstallProtocolType}" | grep -q ",0," || [[ -z "${coreInstallType}" ]]; then
        echoContent red "\n ---> 由于环境依赖，请先安装Xray-core的VLESS_TCP_TLS_Vision"
        exit 0
    fi
    echoContent red "=============================================================="
    echoContent yellow "# 如需自定义，请手动复制模版文件到 ${nginxStaticPath} \n"
    local templateIndex redirectOption=$((${#nginxTemplates[@]} + 1))
    for templateIndex in "${!nginxTemplates[@]}"; do
        echoContent yellow "$((templateIndex + 1)).${nginxTemplates[templateIndex]%%|*}"
    done
    echoContent yellow "${redirectOption}.重定向网站（不使用伪装站）"
    echoContent red "=============================================================="
    read -r -p "请选择:" selectInstallNginxBlogType

    if [[ "${selectInstallNginxBlogType}" == "${redirectOption}" ]]; then
        echoContent red "\n=============================================================="
        echoContent skyBlue "📌 重定向配置说明："
        echoContent yellow "• 重定向会替代伪装站点，根路由 / 将直接跳转"
        echoContent yellow "• 代理路径（如 /your-path）不受影响，正常使用"
        echoContent yellow "1.添加重定向"
        echoContent yellow "2.删除重定向"
        echoContent red "=============================================================="
        read -r -p "请选择:" redirectStatus

        if [[ "${redirectStatus}" == "1" ]]; then
            backupNginxConfig backup
            echoContent yellow "\n使用 302 临时重定向，便于随时调整目标 URL。"

            read -r -p "请输入要重定向的完整URL:" redirectDomain

            if [[ -z "${redirectDomain}" ]]; then
                echoContent red " ---> 重定向URL不能为空"
                backupNginxConfig restoreBackup
                exit 0
            fi

            removeNginx302
            addNginx302 "${redirectDomain}"
            handleNginx stop
            handleNginx start
            if [[ -z $(pgrep -f "nginx") ]]; then
                backupNginxConfig restoreBackup
                handleNginx start
                exit 0
            fi
            checkNginx302
            exit 0
        fi
        if [[ "${redirectStatus}" == "2" ]]; then
            removeNginx302
            echoContent green " ---> 移除302重定向成功"
            exit 0
        fi
    fi
    if nginxTemplateArchive "${selectInstallNginxBlogType}" >/dev/null; then
        deployNginxTemplate "${selectInstallNginxBlogType}" || return 1
        echoContent green " ---> 更换伪站成功"
    else
        echoContent red " ---> 选择错误，请重新选择"
        updateNginxBlog
    fi
}
