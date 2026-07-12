#!/bin/sh
# Regenerate mosdns.yaml from template and restart mosdns.
# Used by the admin panel to apply config changes at runtime.
. /etc/profile

if [ -f /data/custom_env.ini ]; then
    grep -Eo "^[_a-zA-Z0-9]+=\".+\"" /data/custom_env.ini >/tmp/custom_env.ini
    if [ -f "/tmp/custom_env.ini" ]; then
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/"//g' | sed "s/'//g")
            export "$line"
        done <"/tmp/custom_env.ini"
    fi
fi

if [ "$CNAUTO" = "no" ]; then
    echo "CNAUTO is disabled, nothing to regenerate."
    exit 0
fi

IPREX4='([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])\.([0-9]{1,2}|1[0-9][0-9]|2[0-4][0-9]|25[0-5])'
if [ "$SERVER_IP" = "auto" ]; then
    SERVER_IP=$(ip -o -4 route get 1.0.0.1 | grep -Eo "$IPREX4" | tail -1)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="127.0.0.2"
    fi
    echo "SERVER_IP auto detected: $SERVER_IP"
fi

if [ ! -f /data/mosdns.yaml ]; then
    echo "Template /data/mosdns.yaml not found."
    exit 1
fi

CNFALL_QTIME=$(echo "$CNFALL_QTIME" | grep -Eo "^[0-9]+$" | head -1)
if [ -z "$CNFALL_QTIME" ]; then
    CNFALL_QTIME=3
fi
if [ -z "$CN_RECURSE" ]; then
    CN_RECURSE=yes
fi
case "$ROUTE_MODE" in
foreign_first | gfwlist) ;;
*) ROUTE_MODE=cn_first ;;
esac

# Step 1: Generate /tmp/mosdns.yaml from template based on SOCKS5 setting
if echo "$SOCKS5" | grep -Eoq ":[0-9]+"; then
    sed "s/#socksok//g" /data/mosdns.yaml >/tmp/mosdns.yaml
else
    sed "s/#nosocks//g" /data/mosdns.yaml >/tmp/mosdns.yaml
fi

# Step 2: Apply conditional sed substitutions based on env vars

# IPV6
if [ "$IPV6" = "no" ]; then
    sed -i "s/#ipv6no//g" /tmp/mosdns.yaml
fi
if [ "$IPV6" = "yes" ]; then
    sed -i "s/#ipv6yes//g" /tmp/mosdns.yaml
fi
if [ "$IPV6" = "only6" ]; then
    sed -i "s/#ipv6only6//g" /tmp/mosdns.yaml
fi
if [ "$IPV6" = "yes_only6" ]; then
    sed -i "s/#ipv6cn_only6//g" /tmp/mosdns.yaml
fi
if [ "$IPV6" = "raw" ]; then
    sed -i "s/#ipv6raw//g" /tmp/mosdns.yaml
fi

# CNFALL
if [ "$CNFALL" = "yes" ]; then
    sed -i "s/#cnfall//g" /tmp/mosdns.yaml
    sed -i "s/{CNFALL_QTIME}/$CNFALL_QTIME/g" /tmp/mosdns.yaml
    sed -i "s/qtime: [0-9][0-9]*/qtime: $CNFALL_QTIME/g" /tmp/mosdns.yaml
    if [ "$CN_RECURSE" = "no" ]; then
        sed -i "s/#cn_recurse_no//g" /tmp/mosdns.yaml
    else
        sed -i "s/#cn_recurse_yes//g" /tmp/mosdns.yaml
    fi
    if [ "$EXPIRED_FLUSH" = "yes" ]; then
        sed -i "s/#flushd_un_yes//g" /tmp/mosdns.yaml
    fi
else
    sed -i "s/#nofall//g" /tmp/mosdns.yaml
fi

# CUSTOM_FORWARD
if echo "$CUSTOM_FORWARD" | grep -Eoq ":[0-9]+"; then
    CUSTOM_FORWARD=$(echo "$CUSTOM_FORWARD" | sed 's/"//g')
    sed -i "s/#customforward-seted//g" /tmp/mosdns.yaml
    if echo "$CUSTOM_FORWARD" | grep -q '\['; then
        CUSTOM_FORWARD_SERVER=$(echo "$CUSTOM_FORWARD" | sed 's/\[//' | cut -d']' -f1)
        CUSTOM_FORWARD_PORT=$(echo "$CUSTOM_FORWARD" | sed 's/.*\]://' | sed 's/[^0-9]*//')
    else
        CUSTOM_FORWARD_SERVER=$(echo "$CUSTOM_FORWARD" | cut -d':' -f1)
        CUSTOM_FORWARD_PORT=$(echo "$CUSTOM_FORWARD" | cut -d':' -f2)
    fi
    sed -i "s/{CUSTOM_FORWARD}/$CUSTOM_FORWARD/g" /tmp/mosdns.yaml
    sed -i "s/{CUSTOM_FORWARD_SERVER}/$CUSTOM_FORWARD_SERVER/g" /tmp/mosdns.yaml
    sed -i "s/{CUSTOM_FORWARD_PORT}/$CUSTOM_FORWARD_PORT/g" /tmp/mosdns.yaml
    if [ "$AUTO_FORWARD" = "yes" ]; then
        sed -i "s/#autoforward-yes//g" /tmp/mosdns.yaml
        if [ "$AUTO_FORWARD_CHECK" = "yes" ]; then
            sed -i "s/#autoforward-check//g" /tmp/mosdns.yaml
        else
            sed -i "s/#autoforward-nocheck//g" /tmp/mosdns.yaml
        fi
    fi
else
    AUTO_FORWARD="no"
fi
if [ "$AUTO_FORWARD" = "no" ]; then
    sed -i "s/#autoforward-no//g" /tmp/mosdns.yaml
fi
case "$ROUTE_MODE" in
foreign_first)
    sed -i "s/#route_foreign_first//g" /tmp/mosdns.yaml
    ;;
gfwlist)
    /usr/sbin/watch_list.sh load_gfwlist
    sed -i "s/#route_gfwlist//g" /tmp/mosdns.yaml
    ;;
*)
    sed -i "s/#route_cn_first//g" /tmp/mosdns.yaml
    ;;
esac

# CN_TRACKER
if [ "$CN_TRACKER" = "yes" ]; then
    sed -i "s/#cntracker-yes//g" /tmp/mosdns.yaml
    /usr/sbin/watch_list.sh load_trackerslist
fi

# ADDINFO
if [ "$ADDINFO" = "yes" ]; then
    sed -i "s/#addinfo//g" /tmp/mosdns.yaml
fi

# SHUFFLE
if [ "$SHUFFLE" = "yes" ]; then
    sed -i "s/#shuffle//g" /tmp/mosdns.yaml
fi
if [ "$SHUFFLE" = "lite" ]; then
    sed -i "s/#liteshuffle//g" /tmp/mosdns.yaml
fi
if [ "$SHUFFLE" = "trnc" ]; then
    sed -i "s/#trncshuffle//g" /tmp/mosdns.yaml
fi

# USE_MARK_DATA
if [ "$USE_MARK_DATA" = "yes" ]; then
    sed -i "s/#global_mark_yes//g" /tmp/mosdns.yaml
    if [ ! -f /data/global_mark.dat ]; then
        cp /usr/sbin/global_mark.dat /data/
    fi
    if [ ! -f /tmp/global_mark.dat ] || [ ! -f /tmp/cn_mark.dat ] || [ ! -f /tmp/global_mark_cn.dat ]; then
        /usr/sbin/watch_list.sh load_mark_data
    fi
else
    sed -i "s/#global_mark_no//g" /tmp/mosdns.yaml
fi

# USE_HOSTS
if [ "$USE_HOSTS" = "yes" ]; then
    mosdns eat hosts
    sed -i "s/#usehosts-yes//g" /tmp/mosdns.yaml
    sed -i "s/#usehosts-enable//g" /tmp/mosdns.yaml
fi
if echo "$SERVER_IP" | grep -Eoq "^$IPREX4$"; then
    sed -i "s/#usehosts-yes//g" /tmp/mosdns.yaml
    sed -i "s/#serverip-enable//g" /tmp/mosdns.yaml
    sed -i "s/{SERVER_IP}/$SERVER_IP/g" /tmp/mosdns.yaml
fi

# Merge domain lists
if [ ! -f /data/force_dnscrypt_list.txt ]; then
    cp /usr/sbin/force_dnscrypt_list.txt /data/
fi
if [ ! -f /data/force_recurse_list.txt ]; then
    cp /usr/sbin/force_recurse_list.txt /data/
fi
mosdns eat list /tmp/force_dnscrypt_list.txt /data/force_dnscrypt_list.txt /data/force_nocn_list.txt
mosdns eat list /tmp/force_recurse_list.txt /data/force_recurse_list.txt /data/force_cn_list.txt
if [ -f /data/force_forward_list.txt ]; then
    mosdns eat list /tmp/force_forward_list.txt /data/force_forward_list.txt
else
    touch /tmp/force_forward_list.txt
fi

# RULES_TTL
RULES_TTL=$(echo "$RULES_TTL" | grep -Eo "[0-9]+" | head -1)
if [ -z "$RULES_TTL" ]; then
    RULES_TTL=0
fi
CUSTOM_FORWARD_TTL=$(echo "$CUSTOM_FORWARD_TTL" | grep -Eo "[0-9]+" | head -1)
if [ -z "$CUSTOM_FORWARD_TTL" ]; then
    CUSTOM_FORWARD_TTL=0
fi
if [ "$RULES_TTL" -gt 0 ]; then
    sed -i "s/#ttl_rule_ok//g" /tmp/mosdns.yaml
    sed -i "s/{RULES_TTL}/$RULES_TTL/g" /tmp/mosdns.yaml
    /usr/sbin/watch_list.sh load_ttl_rules
fi
if [ "$CUSTOM_FORWARD_TTL" -gt 0 ]; then
    sed -i "s/#CUSTOM_FORWARD_TTL//g" /tmp/mosdns.yaml
    sed -i "s/{CUSTOM_FORWARD_TTL}/$CUSTOM_FORWARD_TTL/g" /tmp/mosdns.yaml
fi

# HTTP_FILE
if [ "$HTTP_FILE" = "yes" ]; then
    sed -i "s/#http_file_yes//g" /tmp/mosdns.yaml
fi

# Admin panel log
if [ "$ADMIN_PANEL" != "no" ]; then
    sed -i "s/#admin_log//g" /tmp/mosdns.yaml
    sed -i "s/#route_log//g" /tmp/mosdns.yaml
    sed -i "s/{MOSDNS_LISTEN_PORT}/5353/g" /tmp/mosdns.yaml
else
    sed -i "s/#admin_nolog//g" /tmp/mosdns.yaml
    sed -i "s/{MOSDNS_LISTEN_PORT}/53/g" /tmp/mosdns.yaml
fi

# Cache size (use existing MSCACHE from env, or fallback)
if [ -n "$MSCACHE" ]; then
    sed -i "s/{MSCACHE}/$MSCACHE/g" /tmp/mosdns.yaml
else
    sed -i "s/{MSCACHE}/8192/g" /tmp/mosdns.yaml
fi

# Step 3: Apply AddMod (custom_mod.yaml zones)
touch /data/custom_mod.yaml
cp /tmp/mosdns.yaml /tmp/mosdns_base.yaml
mosdns AddMod
if [ -f /tmp/mosdns_mod.yaml ]; then
    cat /tmp/mosdns_mod.yaml >/tmp/mosdns.yaml
fi
sed -i '/^#/d' /tmp/mosdns.yaml

# Step 4: Kill old mosdns and start new one
while ps | grep -v grep | grep -q "mosdns.yaml"; do
    mosdns_id=$(ps | grep -v "grep" | grep "mosdns.yaml" | grep -Eo "[0-9]+" | head -1)
    kill "$mosdns_id" 2>/dev/null
done
echo "mosdns regen reload..."
mosdns start -d /tmp -c /tmp/mosdns.yaml >/tmp/mosdns_reload.log 2>&1 &
sleep 1
ps -ef | grep -v "grep" | grep "mosdns"
echo "regen_mosdns done."
