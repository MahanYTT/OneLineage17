#!/bin/sh
# Unit tests for the DNS self-heal in net_fix.sh (embedded in master_prepare.sh).
. "$(dirname "$0")/lib.sh"
echo "net_fix"
NETFIX=$(extract master_prepare__NETFIX)

setup() {
    T=$(tmpdir)
    STUBS="$T/bin"
    mkdir -p "$T/flags" "$T/state"
    stub ip 'case "$*" in
        "-4 addr show wlan0") echo "    inet 192.168.1.50/24 brd 192.168.1.255 scope global wlan0" ;;
        "-4 addr show"*) ;;
        "route show table all") echo "192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.50"
                                echo "default via 192.168.1.1 dev wlan0 table 1003 proto static" ;;
        "rule show") echo "14999:	from all lookup 4242" ;;
        *) echo "ip $*" >> "'"$T"'/ip_calls" ;;
    esac'
    # ping behaviour is driven by files: ip_down, dns_down (resolution fails),
    # icmp_blocked (names resolve but nobody answers), fixed_after_ndc
    stub ping 'host=""; for a in "$@"; do host=$a; done
        case "$host" in
            [0-9]*) [ -f "'"$T"'/ip_down" ] && exit 1; exit 0 ;;
            *) if [ -f "'"$T"'/dns_down" ] && ! { [ -f "'"$T"'/fixed_after_ndc" ] && [ -f "'"$T"'/ndc_calls" ]; }; then
                   echo "ping: unknown host $host" >&2; exit 2; fi
               [ -f "'"$T"'/icmp_blocked" ] && exit 1; exit 0 ;;
        esac'
    stub dumpsys 'echo "Active default network: 104"
        echo "NetworkAgentInfo{network{100}  ni{WIFI} lp{{InterfaceName: wlan0 DnsAddresses: [ /10.0.0.1 ] }}}"
        echo "NetworkAgentInfo{network{104}  ni{WIFI} lp{{InterfaceName: wlan0 DnsAddresses: [ /192.168.1.1,/fe80::1 ] }}}"'
    stub ndc 'echo "ndc $*" >> "'"$T"'/ndc_calls"'
    stub svc 'echo "svc $*" >> "'"$T"'/svc_calls"'
}
run() { LINEAGE_FLAGS="$T/flags" NET_STATE_DIR="$T/state" PATH="$STUBS:$PATH" "$TEST_SH" -c 'sleep() { :; }; . "$0"' "$NETFIX" > "$T/out" 2>&1; }

setup
run
assert_no_file "$T/ndc_calls" "healthy network: resolver untouched"
assert_no_file "$T/svc_calls" "healthy network: wifi untouched"

setup
touch "$T/icmp_blocked"
run
assert_no_file "$T/ndc_calls" "ICMP blocked but DNS fine: no false heal (old code bounced wifi here)"

setup
touch "$T/dns_down" "$T/fixed_after_ndc"
run
assert_grep "ndc network default set 104" "$T/ndc_calls" "re-asserts the current default netId"
assert_grep "ndc resolver setnetdns 104  192.168.1.1$" "$T/ndc_calls" "sets the network's own IPv4 DNS for netId 104"
assert_grep "ndc resolver flushnet 104" "$T/ndc_calls" "flushes netId 104, not a hard-coded 100"
assert_grep "names resolve again" "$T/out" "reports the result"
assert_no_file "$T/svc_calls" "never bounces wifi by default"

setup
touch "$T/dns_down"
echo 9.9.9.9,1.1.1.1 > "$T/flags/dns_servers"
run
assert_grep "setnetdns 104  9.9.9.9 1.1.1.1" "$T/ndc_calls" "dns_servers flag overrides the resolvers"
assert_grep "still failing" "$T/out" "reports a heal that did not help"
assert_no_file "$T/svc_calls" "still no wifi bounce without net_bounce=1"

setup
touch "$T/dns_down"
run; rm -f "$T/ndc_calls"; run
assert_no_file "$T/ndc_calls" "rate limited: no second heal within 20 s"

setup
touch "$T/dns_down"
echo 1 > "$T/flags/net_bounce"
run
assert_grep "svc wifi disable" "$T/svc_calls" "net_bounce=1: bounces wifi as a last resort"
rm -f "$T/state/net_dns_fix.ts" "$T/svc_calls"; run
assert_no_file "$T/svc_calls" "net_bounce=1: backoff blocks an immediate second bounce"

setup
touch "$T/dns_down"
echo 0 > "$T/flags/dns_heal"
run
assert_no_file "$T/ndc_calls" "dns_heal=0 disables the repair"

setup
touch "$T/ip_down" "$T/dns_down"
run
assert_no_file "$T/ndc_calls" "no IP connectivity: DNS heal does not fire"

finish
