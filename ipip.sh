#!/bin/bash

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

install_ipip(){
    if ! lsmod | grep -q "ipip"; then
        modprobe ipip
    fi
    if ! command -v dig >/dev/null 2>&1; then
        apt-get install dnsutils -y >/dev/null 2>&1 || yum install dnsutils -y >/dev/null 2>&1
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        apt install iptables -y >/dev/null 2>&1 || yum install iptables -y >/dev/null 2>&1
    fi

    echo -ne "请输入对端设备的ddns域名或者IP："
    read ddnsname
    read -p "请输入要创建的tun网卡名称(例如 tun0)：" tunname
    echo -ne "请输入tun网口的V-IP："
    read vip
    echo -ne "请输入对端的V-IP："
    read remotevip

    # 创建隧道启动脚本
    cat > /usr/local/bin/ipip-up-${tunname}.sh <<EOF
#!/bin/bash
remoteip=\$(ping -4 -c 1 -W 2 "${ddnsname}" | grep PING | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
[[ -z "\$remoteip" ]] && remoteip="${ddnsname}"

netcardname=\$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
localip=\$(ip -4 a show dev "\$netcardname" | grep global | awk '{print \$2}' | cut -d '/' -f 1 | head -1)

ip tunnel add ${tunname} mode ipip remote \$remoteip local \$localip ttl 64
ip addr add ${vip}/30 dev ${tunname}
ip link set ${tunname} up
ip route add ${remotevip}/32 dev ${tunname} scope link src ${vip}

if ! iptables -t nat -L | grep -q "${remotevip}"; then
    iptables -t nat -A POSTROUTING -s ${remotevip} -j MASQUERADE
fi
if ! sysctl -p | grep -q "net.ipv4.ip_forward = 1"; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf
fi
EOF
    chmod +x /usr/local/bin/ipip-up-${tunname}.sh

    # 创建隧道停止脚本
    cat > /usr/local/bin/ipip-down-${tunname}.sh <<EOF
#!/bin/bash
ip link set ${tunname} down
ip tunnel del ${tunname}
EOF
    chmod +x /usr/local/bin/ipip-down-${tunname}.sh

    # 创建隧道 systemd 服务
    cat > /etc/systemd/system/ipip-${tunname}.service <<EOF
[Unit]
Description=IPIP Tunnel ${tunname}
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ipip-up-${tunname}.sh
ExecStop=/usr/local/bin/ipip-down-${tunname}.sh

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ipip-${tunname}.service
    systemctl restart ipip-${tunname}.service
    echo "IPIP 隧道 ${tunname} 原生服务已启动"

    # 如果是 DDNS 域名，创建守护进程服务监控变动 (取代 cron)
    if [[ ! "$ddnsname" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        cat > /usr/local/bin/ipip-ddns-${tunname}.sh <<EOF
#!/bin/bash
while true; do
    remoteip=\$(ping -4 -c 1 -W 2 "${ddnsname}" | grep PING | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    oldip=\$(cat /root/.tunnel-ip-${tunname}.txt 2>/dev/null)
    
    if [[ -n "\$remoteip" && "\$remoteip" != "\$oldip" ]]; then
        echo "\$remoteip" > /root/.tunnel-ip-${tunname}.txt
        if [[ -n "\$oldip" ]]; then
            echo "IP 发生变动: \$oldip -> \$remoteip, 正在重启隧道..."
            systemctl restart ipip-${tunname}.service
            # 若有关联的 wg，尝试平滑重连
            systemctl restart wg-quick@wg0 2>/dev/null
        fi
    fi
    sleep 120
done
EOF
        chmod +x /usr/local/bin/ipip-ddns-${tunname}.sh

        cat > /etc/systemd/system/ipip-ddns-${tunname}.service <<EOF
[Unit]
Description=IPIP DDNS Monitor for ${tunname}
After=network.target ipip-${tunname}.service

[Service]
Type=simple
ExecStart=/usr/local/bin/ipip-ddns-${tunname}.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ipip-ddns-${tunname}.service
        systemctl restart ipip-ddns-${tunname}.service
        echo "DDNS 监控守护进程已独立启动 (每120秒检测一次)"
    fi

    echo "程序全部执行完毕，脚本退出。"
    exit 0
}

install_ipipv6(){
    if ! lsmod | grep -q "tunnel6"; then
        modprobe ip6_tunnel
    fi
    if ! command -v iptables >/dev/null 2>&1; then
        apt install iptables -y >/dev/null 2>&1 || yum install iptables -y >/dev/null 2>&1
    fi

    echo -ne "请输入对端设备的ddns域名或者IP："
    read ddnsname
    read -p "请输入要创建的tun网卡名称：" tunname
    echo -ne "请输入tun网口的V-IP："
    read vip
    echo -ne "请输入对端的V-IP："
    read remotevip

    read -p "当前机器是甲骨文吗？[Y/n]:" yn

    # 创建隧道启动脚本
    cat > /usr/local/bin/ipipv6-up-${tunname}.sh <<EOF
#!/bin/bash
netcardname=\$(ip -6 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
[[ -z "\$netcardname" ]] && netcardname=\$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

if [[ "${yn}" =~ ^[Yy]$ ]]; then
    sleep 20s
    dhclient -6 \$netcardname
fi

routerule=\$(ip -6 route list | grep default | head -1 | awk '{print \$1" "\$2" "\$3" "\$4" "\$5}')
localip6=\$(ip -6 a show dev "\$netcardname" | grep 'scope global' | awk '{print \$2}' | cut -d '/' -f 1 | head -1)

remoteip=\$(ping -6 -c 1 -W 2 "${ddnsname}" | grep PING | grep -Eo '([0-9a-fA-F]{1,4}:)+[0-9a-fA-F]{1,4}' | head -n1)
[[ -z "\$remoteip" ]] && remoteip="${ddnsname}"

ip link add name ${tunname} type ip6tnl local \${localip6} remote \${remoteip} mode any
ip addr add ${vip}/30 dev ${tunname}
ip link set ${tunname} up
ip -6 route add \$routerule

if ! iptables -t nat -L | grep -q "${remotevip}"; then
    iptables -t nat -A POSTROUTING -s ${remotevip} -j MASQUERADE
fi
if ! sysctl -p | grep -q "net.ipv6.conf.all.forwarding=1"; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf
fi
EOF
    chmod +x /usr/local/bin/ipipv6-up-${tunname}.sh

    # 创建隧道停止脚本
    cat > /usr/local/bin/ipipv6-down-${tunname}.sh <<EOF
#!/bin/bash
ip link set ${tunname} down
ip tunnel del ${tunname}
EOF
    chmod +x /usr/local/bin/ipipv6-down-${tunname}.sh

    # 创建 systemd 服务
    cat > /etc/systemd/system/ipipv6-${tunname}.service <<EOF
[Unit]
Description=IPv6 IPIP Tunnel ${tunname}
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ipipv6-up-${tunname}.sh
ExecStop=/usr/local/bin/ipipv6-down-${tunname}.sh

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ipipv6-${tunname}.service
    systemctl restart ipipv6-${tunname}.service
    echo "IPv6 隧道 ${tunname} 服务已部署"

    # DDNS 监控服务
    if [[ ! "$ddnsname" =~ ":" ]]; then
        cat > /usr/local/bin/ipipv6-ddns-${tunname}.sh <<EOF
#!/bin/bash
while true; do
    remoteip=\$(ping -6 -c 1 -W 2 "${ddnsname}" | grep PING | grep -Eo '([0-9a-fA-F]{1,4}:)+[0-9a-fA-F]{1,4}' | head -n1)
    oldip=\$(cat /root/.tunnel-ipv6-${tunname}.txt 2>/dev/null)
    if [[ -n "\$remoteip" && "\$remoteip" != "\$oldip" ]]; then
        echo "\$remoteip" > /root/.tunnel-ipv6-${tunname}.txt
        if [[ -n "\$oldip" ]]; then
            systemctl restart ipipv6-${tunname}.service
            systemctl restart wg-quick@wg0 2>/dev/null
        fi
    fi
    sleep 120
done
EOF
        chmod +x /usr/local/bin/ipipv6-ddns-${tunname}.sh

        cat > /etc/systemd/system/ipipv6-ddns-${tunname}.service <<EOF
[Unit]
Description=IPv6 DDNS Monitor for ${tunname}
After=network.target ipipv6-${tunname}.service

[Service]
Type=simple
ExecStart=/usr/local/bin/ipipv6-ddns-${tunname}.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ipipv6-ddns-${tunname}.service
        systemctl restart ipipv6-ddns-${tunname}.service
    fi

    if [[ "$yn" =~ ^[Yy]$ ]]; then
        echo -e "${red}提示:${plain}${yellow} 你的机器是甲骨文，服务可能需要系统彻底重置网卡才能完美工作。${plain}"
    fi
    exit 0
}

install_wg(){
    apt-get update 
    apt-get install wireguard -y
    if [[ ! -f /etc/wireguard/privatekey ]]; then
        wg genkey | tee /etc/wireguard/privatekey | wg pubkey | tee /etc/wireguard/publickey
    fi
    localprivatekey=$(cat /etc/wireguard/privatekey)
    netcardname=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

    read -p "请输入对端wg使用的V-ip地址:" revip
    read -p "请输入本机wg使用的v-ip地址:" localip1
    read -p "请输入RouterOS端wg的公钥内容:" rospublickey
    read -p "请输入RouterOS端wg调用的端口号:" wgport

    allowedip1=$(echo "$revip" | awk -F "." '{print $1"."$2"."$3}')
    
    filename="wg0"
    if [[ -f /etc/wireguard/wg0.conf ]]; then
        read -p "请给本机wg配置文件取个名(英文):" filename
        if [[ -f "/etc/wireguard/${filename}.conf" ]]; then
            echo "⚠️  已存在同样名称的配置文件，程序退出，请重新执行程序。"
            exit 1
        fi
    fi

    read -p "请输入对端ipip隧道IP段(例如 192.168.2.1 只填写 192.168.2 即可)：" ipduan
    read -p "请输入对端ipip隧道的IP地址：" ipaddrremote

    cat > "/etc/wireguard/$filename.conf" <<EOF
[Interface]
ListenPort = $wgport
Address = $localip1/24
PostUp   = iptables -t nat -A POSTROUTING -o $netcardname -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $netcardname -j MASQUERADE
PrivateKey = $localprivatekey
	
[Peer]
PublicKey = $rospublickey
AllowedIPs = $ipduan.0/24,$allowedip1.0/24
Endpoint = ${ipaddrremote}:$wgport
PersistentKeepalive = 25
EOF

    chmod 600 "/etc/wireguard/$filename.conf"
    
    # 彻底使用 systemctl 管理 WireGuard
    systemctl enable wg-quick@${filename}
    systemctl start wg-quick@${filename}

    vpspublickey=$(cat /etc/wireguard/publickey)
    linstenport=$(grep "ListenPort" "/etc/wireguard/$filename.conf" | awk '{print $3}')
    vip=$(ip a | grep "scope global" | grep "/30" | awk '{print $2}' | cut -d '/' -f 1 | head -1)
    
    echo "    "
    echo -e "${green}------------------------------------------------------------${plain}"
    echo -e "${green}请在 MikroTik RouterOS 的 wireguard 选项卡里边的 Peers 里添加配置，具体填写如下信息：${plain}"
    echo -e "Public key 填写：${yellow}${vpspublickey}${plain}"
    if [[ "$filename" == "wg0" && -n "$vip" ]]; then
        echo -e "Endpoint 填写：${yellow}${vip}${plain}"
    fi
    echo -e "Endpoint port 填写：${yellow}${linstenport}${plain}"
    echo -e "Allowed Address 填写：${green}0.0.0.0/0\n祝使用愉快。${plain}"
}

keep_alive(){
    read -p "请输入对端ipip隧道IP：" remoteip_1
    cat > /usr/local/bin/ipip-keepalive.sh <<EOF
#!/bin/bash
while true; do
    ping -4 -c 1 -W 2 "${remoteip_1}" >/dev/null 2>&1
    sleep 2
done
EOF
    chmod +x /usr/local/bin/ipip-keepalive.sh

    cat > /etc/systemd/system/ipip-keepalive.service <<EOF
[Unit]
Description=IPIP Tunnel Keepalive Ping
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ipip-keepalive.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ipip-keepalive.service
    systemctl start ipip-keepalive.service
    echo -e "${yellow}IPIP隧道原生保活服务配置完成，已在后台运行。${plain}"
}

copyright(){
    clear
    echo -e "
${green}###########################################################${plain}
${green}#                                                         #${plain}
${green}#        IPIP tunnel隧道、Wireguard一键部署脚本 (Systemd版)    #${plain}
${green}#                Power By:翔翎                              #${plain}
${green}#                                                         #${plain}
${green}###########################################################${plain}"
}

main(){
    copyright
    echo -e "
${red}0.${plain}  退出脚本
${green}———————————————————————————————————————————————————————————${plain}
${green}1.${plain}  一键部署IPIP隧道
${green}2.${plain}  一键部署${red}IPIPv6${plain}隧道
${green}3.${plain}  一键部署wireguard
${green}4.${plain}  IPIP隧道保活
"
    echo -e "${yellow}请选择你要使用的功能${plain}"
    read -p "请输入数字 :" num   
    case "$num" in
        0) exit 0 ;;
        1) install_ipip ;;
        2) install_ipipv6 ;;
        3) install_wg ;;
        4) keep_alive ;;
        *)
            clear
            echo -e "${red}出现错误:请输入正确数字 ${plain}"
            sleep 2
            main
            ;;
    esac
}

main
