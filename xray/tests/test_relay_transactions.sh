#!/usr/bin/env bash
#
# Relay changes are transactional: a change that Xray rejects must leave the
# config directory and relay state exactly as they were.

# Globals are shared with the sourced modules, which ShellCheck cannot see.
# shellcheck disable=SC2034,SC2154

set -euo pipefail

testDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${testDirectory}/load_modules.sh"

temporaryDirectory=$(mktemp -d /tmp/xray-relay-transactions-test.XXXXXX)
trap 'rm -rf "${temporaryDirectory}"' EXIT

configPath="${temporaryDirectory}/conf/"
relayStateFile="${temporaryDirectory}/relay_config.json"
relayLockFile="${temporaryDirectory}/relay.lock"
mkdir -p "${configPath}"

# Fake Xray: rejects the config when any file contains the word INVALID.
xrayBinary="${temporaryDirectory}/xray"
cat >"${xrayBinary}" <<'XRAY'
#!/usr/bin/env bash
confdir=${@: -1}
if grep -rq INVALID "${confdir}"; then
    echo "fake xray: invalid outbound"
    exit 1
fi
XRAY
chmod +x "${xrayBinary}"

echoContent() { :; }
restartXray() { :; }
installCronRelaySubscription() { :; }
removeCronRelaySubscription() { :; }

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

reset_fixture() {
    rm -rf "${configPath}"
    mkdir -p "${configPath}"
    jq -n '{version:2,profiles:[
        {id:"us",name:"us",source:"manual",outboundTag:"relay_profile_us",outboundFile:"relay_us_outbound.json",
         selectors:[
            {inboundTags:["VLESSTCP"],users:["alice-VLESS_TCP/TLS_Vision"]},
            {inboundTags:["VLESSTCP"],users:["alice-VLESS_TCP/TLS_Vision","bob-VLESS_TCP/TLS_Vision"]},
            {inboundTags:["Hysteria2"],users:[]}
         ],
         tcp:{label:"ss"},udp:{mode:"direct"}},
        {id:"jp",name:"jp",source:"manual",outboundTag:"relay_profile_jp",outboundFile:"relay_jp_outbound.json",
         selectors:[{inboundTags:["VLESSWS"],users:[]}],tcp:{label:"ss"},udp:{mode:"direct"}}
    ]}' >"${relayStateFile}"
    echo '{"outbounds":[{"tag":"relay_profile_us"}]}' >"${configPath}relay_us_outbound.json"
    echo '{"outbounds":[{"tag":"relay_profile_jp"}]}' >"${configPath}relay_jp_outbound.json"
    echo '{"routing":{"rules":[{"type":"field","domain":["geosite:private"],"outboundTag":"direct"}]}}' >"${configPath}09_routing.json"
}

snapshot() {
    (cd "${temporaryDirectory}" && find conf -type f | sort | xargs cat && cat relay_config.json)
}

# Successful change: the deleted profile's outbound file is removed and its
# routes disappear.
reset_fixture
commitRelayChange "test" updateRelayState jq 'del(.profiles[] | select(.id == "jp"))' "${relayStateFile}" \
    || fail "valid change should commit"
[[ ! -f "${configPath}relay_jp_outbound.json" ]] || fail "orphaned outbound should be removed"
jq -e '[.routing.rules[] | select(.outboundTag == "relay_profile_jp")] | length == 0' "${configPath}09_routing.json" >/dev/null \
    || fail "routes to the removed profile should be gone"
jq -e '.routing.rules[0].outboundTag == "relay_profile_us"' "${configPath}09_routing.json" >/dev/null \
    || fail "account rules should come first"

# Rejected change: everything is restored, including removing new files.
reset_fixture
before=$(snapshot)
breakConfig() {
    echo '{"outbounds":[{"tag":"INVALID"}]}' >"${configPath}relay_new_outbound.json"
    writeRelayState '{"version":2,"profiles":[]}'
}
if commitRelayChange "test" breakConfig; then
    fail "a change Xray rejects must fail"
fi
[[ "$(snapshot)" == "${before}" ]] || fail "rejected change must restore config and state exactly"

# Deleting accounts: selectors that only listed them are dropped, never
# widened to the whole inbound.
reset_fixture
removeRelayUsers "alice-VLESS_TCP/TLS_Vision" || fail "removeRelayUsers should succeed"
jq -e '
    (first(.profiles[] | select(.id == "us")).selectors ==
        [{inboundTags:["VLESSTCP"],users:["bob-VLESS_TCP/TLS_Vision"]},
         {inboundTags:["Hysteria2"],users:[]}])
' "${relayStateFile}" >/dev/null || fail "removeRelayUsers produced the wrong selectors"

# A missing routing file is recreated instead of failing every relay action.
reset_fixture
rm -f "${configPath}09_routing.json"
syncRelayRouting || fail "syncRelayRouting should recreate 09_routing.json"
jq -e '.routing.rules | length > 0' "${configPath}09_routing.json" >/dev/null || fail "relay rules missing after recreate"

# Subscriptions must use HTTPS.
if fetchRelaySubscription "http://example.com/sub.json" "${temporaryDirectory}/sub.json"; then
    fail "plain HTTP subscriptions must be rejected"
fi

# Shadowsocks nodes that need a SIP003 plugin cannot work in Xray.
jq -n '{outbounds:[
    {type:"shadowsocks",tag:"plain",server:"a",server_port:1,method:"aes-256-gcm",password:"x"},
    {type:"shadowsocks",tag:"obfs",server:"b",server_port:2,method:"aes-256-gcm",password:"x",plugin:"obfs-local"}
]}' >"${temporaryDirectory}/sub.json"
nodes=$(getRelayNodesFromSingBoxSubscription "${temporaryDirectory}/sub.json")
jq -e 'map(.tag) == ["plain"]' <<<"${nodes}" >/dev/null || fail "plugin nodes must be skipped"

# Relay outbound files are renamed to *_tail_outbound.json, which Xray
# appends instead of prepending, so a relay never becomes the default
# outbound (e.g. in the IPv6 global mode, where z_direct_outbound.json is gone).
reset_fixture
ensureRelayStateV2 || fail "migration failed"
[[ "${relayOutboundFilesMigrated}" == "true" ]] || fail "migration should report renamed files"
[[ -f "${configPath}relay_us_tail_outbound.json" && ! -f "${configPath}relay_us_outbound.json" ]] || fail "relay_us file not renamed"
[[ -f "${configPath}relay_jp_tail_outbound.json" && ! -f "${configPath}relay_jp_outbound.json" ]] || fail "relay_jp file not renamed"
jq -e '[.profiles[].outboundFile] == ["relay_us_tail_outbound.json","relay_jp_tail_outbound.json"]' "${relayStateFile}" >/dev/null \
    || fail "state must point at the renamed files"
ensureRelayStateV2 || fail "second migration failed"
[[ -z "${relayOutboundFilesMigrated}" ]] || fail "migration must be a no-op the second time"
relayProfileFileIsSafe relay_123_456_tail_outbound.json || fail "new file names must pass the safety check"
removeOrphanedRelayFiles
[[ -f "${configPath}relay_us_tail_outbound.json" ]] || fail "orphan cleanup must keep the renamed files"

# Subscription refresh: a renamed node on the same server is followed; the
# first node of the subscription (here an information entry) is never used.
reset_fixture
jq '.profiles[0] += {source:"subscription",outboundFile:"relay_us_tail_outbound.json",
    subscription:{format:"sing-box-json",url:"https://example.com/sub.json",selectedTag:"US 01 | 剩余 80G",nodeType:"shadowsocks"},
    tcp:{mode:"relay",protocol:"shadowsocks",label:"ss",address:"203.0.113.7",port:"8388"}}' "${relayStateFile}" >"${relayStateFile}.new"
mv "${relayStateFile}.new" "${relayStateFile}"
mv "${configPath}relay_us_outbound.json" "${configPath}relay_us_tail_outbound.json"
subscriptionNodes='{"outbounds":[
    {type:"shadowsocks",tag:"剩余流量：70 GB",server:"127.0.0.1",server_port:1,method:"aes-256-gcm",password:"x"},
    {type:"shadowsocks",tag:"US 01 | 剩余 70G",server:"203.0.113.7",server_port:8388,method:"aes-256-gcm",password:"new"}]}'
fetchRelaySubscription() { jq -n "${subscriptionNodes}" >"$2"; }
updateRelaySubscriptionProfile us >/dev/null || fail "a renamed node on the same server should be followed"
jq -e 'first(.profiles[] | select(.id == "us")).subscription.selectedTag == "US 01 | 剩余 70G"' "${relayStateFile}" >/dev/null \
    || fail "the renamed tag should be recorded"
jq -e '.outbounds[0].settings.address == "203.0.113.7" and .outbounds[0].settings.password == "new"' \
    "${configPath}relay_us_tail_outbound.json" >/dev/null || fail "the outbound should follow the same server"
# The server is gone: keep the working config instead of switching nodes.
subscriptionNodes='{"outbounds":[
    {type:"shadowsocks",tag:"剩余流量：60 GB",server:"127.0.0.1",server_port:1,method:"aes-256-gcm",password:"x"},
    {type:"shadowsocks",tag:"JP 01",server:"198.51.100.9",server_port:8388,method:"aes-256-gcm",password:"y"}]}'
before=$(snapshot)
if updateRelaySubscriptionProfile us >/dev/null; then
    fail "a subscription without the node's server must not switch nodes"
fi
[[ "$(snapshot)" == "${before}" ]] || fail "the old config must be kept when the node is gone"

# Nested lock use must not deadlock and must keep the inner status.
innerFails() { return 3; }
status=0
withRelayLock withRelayLock innerFails || status=$?
[[ ${status} -eq 3 ]] || fail "withRelayLock should return the command's status"

echo "relay transaction tests passed"
