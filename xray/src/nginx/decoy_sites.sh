# Decoy sites. The pages are built with Astro in xray/decoy-sites/ (one zip
# per site in its dist/ directory) and hold __KEY__ placeholders. Names,
# colours, cities and dates are filled in per install, so servers using the
# same site do not serve identical pages.

decoySiteBase=https://raw.githubusercontent.com/z9wen/vps-scripts/main/xray/decoy-sites/dist

# Menu label and site name (dist/<site>.zip), in menu order.
nginxTemplates=(
    "企业官网 · 供应链软件|corp-cn"
    "Company site · engineering consultancy|corp-en"
    "游戏工作室|game-studio"
    "技术博客|tech-blog"
    "生活随笔博客|life-blog"
    "资源节点（如 vod-s1.域名）|resource-node"
)

# One of the arguments, at random.
decoyPick() {
    local -a options=("$@")
    echo "${options[RANDOM % ${#options[@]}]}"
}

# Date $1 days ago as YYYY-MM-DD (GNU date; BSD date for local tests).
decoyDate() {
    local seconds=$(($(date +%s) - $1 * 86400))
    date -d "@${seconds}" +%Y-%m-%d 2>/dev/null || date -r "${seconds}" +%Y-%m-%d
}

# Replace __KEY__ placeholders in every page (and JSON file) under
# directory $1 with the KEY=value arguments. Values come from the lists
# below or the domain: none contains "|" or "&".
decoyFill() {
    local dir=$1 pair page
    local -a expressions=()
    shift
    for pair in "$@"; do
        expressions+=(-e "s|__${pair%%=*}__|${pair#*=}|g")
    done
    while IFS= read -r page; do
        sed "${expressions[@]}" "${page}" >"${page}.tmp" && mv -f "${page}.tmp" "${page}"
    done < <(find "${dir}" -type f \( -name '*.html' -o -name '*.json' \))
}

# The resource node's name and service, from the domain it is served on:
# vod-s1.example.com is node "vod-s1" of a video edge. A bare domain gets a
# generic edge name. Prints NODE, KIND, SERVICE and SERVICE_ID lines.
decoyResourceNode() {
    local host=$1 node
    node=${host%%.*}
    if [[ "${host}" != *.*.* || ! "${node}" =~ ^[a-z0-9-]+$ ]]; then
        node="edge-$(printf '%02d' $((1 + RANDOM % 24)))"
    fi
    echo "NODE=${node}"
    case ${node} in
        vod* | video* | media* | stream* | live* | play*)
            echo "KIND=Media Edge Node"
            echo "SERVICE=VOD edge · HLS / DASH segments"
            echo "SERVICE_ID=vod"
            ;;
        img* | image* | pic* | static* | cdn* | assets* | res*)
            echo "KIND=Static Edge Node"
            echo "SERVICE=Static assets · images, scripts, styles"
            echo "SERVICE_ID=static"
            ;;
        dl* | download* | mirror* | files* | pkg* | update*)
            echo "KIND=Download Node"
            echo "SERVICE=Downloads · packages and large files"
            echo "SERVICE_ID=download"
            ;;
        *)
            echo "KIND=Edge Node"
            echo "SERVICE=Edge cache · cached content"
            echo "SERVICE_ID=edge"
            ;;
    esac
}

# The placeholder values of site $1, one KEY=value per line.
decoySiteValues() {
    local year
    year=$(date +%Y)
    echo "DOMAIN=${domain:-${currentHost:-localhost}}"
    echo "YEAR=${year}"
    echo "TODAY=$(decoyDate 0)"
    case $1 in
        corp-cn)
            echo "NAME=$(decoyPick 澜舟科技 青禾数据 启明云链 远帆智能 栖木软件 观潮信息)"
            echo "PRODUCT=$(decoyPick 舟仓 禾链 明仓 帆运 木栈 潮汐)"
            echo "CITY=$(decoyPick 上海市徐汇区 杭州市西湖区 苏州市工业园区 深圳市南山区 成都市高新区 武汉市东湖高新区)"
            echo "HUE=$(decoyPick 168 196 212 152 228)"
            ;;
        corp-en)
            echo "NAME=$(decoyPick "Halden Systems" "Brightwater Analytics" "Kestrel Works" "Ardent Ridge" "Lowmoor Engineering" "Fenwick and Hale")"
            echo "CITY=$(decoyPick Rotterdam Toronto Melbourne Edinburgh Copenhagen Wellington)"
            echo "HUE=$(decoyPick 222 205 260 190 18)"
            ;;
        game-studio)
            echo "NAME=$(decoyPick 雾港互动 拾光游戏 星屿工作室 潮声游戏 远山互动 夜航工作室)"
            echo "NAME_EN=$(decoyPick Harborfog "Lumen Pier" "Isle Seven" Tidewalk "Far Ridge" "Night Ferry")"
            # The featured game and its one-line story are picked together.
            local -a games=(
                "灯塔守望者|一座在雾里亮了一百年的灯塔，一个刚来报到的守望者。白天修补零件、整理航海日志，夜里点亮灯光，等那些迷路的船回来。"
                "回声群岛|七座小岛，一个只能听见回声的向导。顺着声音找到失散的岛民，拼出群岛沉默了二十年的原因。"
                "最后一班渡轮|港口明天就要关闭，你是最后一班渡轮的船长。一晚的航程，十二位乘客，每个人都带着一个没说出口的故事。"
                "雾中邮差|起雾的小镇只剩下你一个邮差。挨家挨户送完积压的信，也慢慢读懂了这座小镇为什么总是起雾。"
                "沉睡的星图|外婆留下一张画满星星的旧地图。照着它走遍海边的灯塔和山顶的观测站，找回她年轻时看过的那片星空。"
            )
            local game
            game=$(decoyPick "${games[@]}")
            echo "GAME1=${game%%|*}"
            echo "GAME1_STORY=${game#*|}"
            echo "GAME2=$(decoyPick 小镇面包房 风筝与少年 纸箱宇宙 山居手记)"
            echo "GAME3=$(decoyPick 代号：潮汐 代号：北极星 代号：远航 代号：萤火)"
            echo "HUE=$(decoyPick 265 200 330 160 25)"
            echo "DATE1=$(decoyDate $((5 + RANDOM % 9)))"
            echo "DATE2=$(decoyDate $((24 + RANDOM % 20)))"
            echo "DATE3=$(decoyDate $((60 + RANDOM % 30)))"
            echo "DATE4=$(decoyDate $((110 + RANDOM % 40)))"
            ;;
        tech-blog)
            echo "BLOG=$(decoyPick 折腾札记 慢慢写代码 半夜的终端 一行一行 工具箱 后端随手记)"
            echo "AUTHOR=$(decoyPick 阿木 小舟 林间 老陈 南风 一川)"
            echo "HUE=$(decoyPick 210 150 20 280 190)"
            echo "DATE1=$(decoyDate $((3 + RANDOM % 10)))"
            echo "DATE2=$(decoyDate $((30 + RANDOM % 25)))"
            echo "DATE3=$(decoyDate $((80 + RANDOM % 40)))"
            echo "YEAR_1=$((year - 1))"
            echo "YEAR_2=$((year - 2))"
            echo "YEAR_3=$((year - 3))"
            ;;
        life-blog)
            echo "BLOG=$(decoyPick 慢慢走 晴天记 周末去哪儿 一碗面的时间 河边散步 小记)"
            echo "AUTHOR=$(decoyPick 苏苏 阿树 晚晚 小林 七月 叶子)"
            echo "HUE=$(decoyPick 205 150 12 330 45)"
            echo "DATE1=$(decoyDate $((2 + RANDOM % 8)))"
            echo "DATE2=$(decoyDate $((18 + RANDOM % 15)))"
            echo "DATE3=$(decoyDate $((45 + RANDOM % 30)))"
            ;;
        resource-node)
            local country
            # The server's country, as Cloudflare sees it; the page shows no addresses.
            country=$(curl -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^loc=//p')
            decoyResourceNode "${domain:-${currentHost:-localhost}}"
            echo "BRAND=$(decoyPick "Lattice Networks" "Meridian Media" "Bluefin CDN" "Cobalt Edge" "Northgate Networks" "Arcadia Media")"
            echo "COUNTRY=${country:-—}"
            echo "POP=${country:-pop}-$((1 + RANDOM % 4))"
            echo "ORIGIN=origin-pool-$((1 + RANDOM % 6))"
            echo "CACHE=$(decoyPick "SSD 960 GB" "SSD 1.92 TB" "NVMe 3.84 TB" "NVMe 7.68 TB")"
            echo "HIT=$(decoyPick 95.9% 96.8% 97.4% 98.1% 98.6%)"
            echo "VERSION=$(decoyPick 2.18.6 3.11.9 3.12.4 3.13.1)"
            echo "SINCE=$(decoyDate $((40 + RANDOM % 160)))"
            echo "HUE=$(decoyPick 190 150 210 30 265)"
            ;;
    esac
}

# Fill site $2's placeholders in directory $1.
decoyPrepareSite() {
    local dir=$1 site=$2 line
    local -a values=()
    while IFS= read -r line; do
        values+=("${line}")
    done < <(decoySiteValues "${site}")
    decoyFill "${dir}" "${values[@]}"
}
