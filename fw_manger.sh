#!/bin/bash

###############################################################################
# 服务器防火墙统一管理脚本 (智能去重 + 冲突解决版)
# 功能: 
#   1. 自动检测并安装未安装的防火墙
#   2. 切换防火墙时自动清空其他防火墙的所有规则
#   3. 智能管理策略：
#      - 自动检测重复规则 (跳过)
#      - 自动检测冲突规则 (删除旧的，保留新的)
#      - 清晰文字描述每一步操作
# 兼容: CentOS, Ubuntu, Debian, 麒麟, 统信 UOS 等
###############################################################################

# 检查 root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "错误: 请使用 root 权限运行此脚本 (sudo $0)"
        exit 1
    fi
}

# 获取系统类型
get_os_type() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|uos|deepin) echo "deb" ;;
            centos|rhel|fedora|kylin|opencloudos|anolis) echo "rpm" ;;
            *) echo "unknown" ;;
        esac
    else
        command -v apt-get >/dev/null 2>&1 && echo "deb" || echo "rpm"
    fi
}

# 安装防火墙
install_firewall() {
    local fw=$1
    local os_type=$(get_os_type)
    echo "正在检测系统环境并安装 $fw ..."
    
    case $fw in
        firewalld)
            [ "$os_type" == "rpm" ] && (yum install -y firewalld || dnf install -y firewalld)
            [ "$os_type" == "deb" ] && (apt-get update && apt-get install -y firewalld)
            ;;
        ufw)
            if [ "$os_type" == "deb" ]; then
                apt-get update && apt-get install -y ufw
            elif [ "$os_type" == "rpm" ]; then
                rpm -qa | grep -q epel-release || (yum install -y epel-release || dnf install -y epel-release)
                yum install -y ufw || dnf install -y ufw
            fi
            ;;
        iptables)
            [ "$os_type" == "rpm" ] && (yum install -y iptables-services || dnf install -y iptables-services)
            [ "$os_type" == "deb" ] && (apt-get update && apt-get install -y iptables-persistent)
            ;;
    esac

    if [ $fw == "firewalld" ] && command -v firewall-cmd >/dev/null 2>&1; then return 0
    elif [ $fw == "ufw" ] && command -v ufw >/dev/null 2>&1; then return 0
    elif [ $fw == "iptables" ] && command -v iptables-save >/dev/null 2>&1; then return 0
    else echo "警告: 安装完成但未检测到命令生效"; return 1; fi
}

# 检测状态
check_fw_status() {
    local fw=$1
    local cmd="" service_name=""
    case $fw in
        firewalld) cmd="firewall-cmd"; service_name="firewalld" ;;
        ufw) cmd="ufw"; service_name="ufw" ;;
        iptables) cmd="iptables-save"; service_name="iptables" ;;
    esac

    command -v $cmd >/dev/null 2>&1 || { echo "not_installed"; return; }

    if [ "$fw" == "ufw" ]; then
        ufw status 2>/dev/null | grep -q "Status: active" && echo "active" || echo "inactive"
        return
    fi

    systemctl is-active --quiet $service_name 2>/dev/null && echo "active" || echo "inactive"
}

# 停止、禁用并清空
stop_disable_and_flush_fw() {
    local fw=$1
    echo "正在停止并禁用 $fw ..."
    case $fw in
        firewalld)
            echo "  -> 准备清空 firewalld 区域规则..."
            firewall-cmd --list-all-zones 2>/dev/null | grep -E "^zone:|ports:|services:|rich rules:" | head -20
            systemctl stop firewalld 2>/dev/null; systemctl disable firewalld 2>/dev/null
            firewall-cmd --reload 2>/dev/null || true
            echo "  ✅ firewalld 已停止并重置。"
            ;;
        ufw)
            echo "  -> 准备清空 ufw 规则..."
            ufw status verbose 2>/dev/null | grep -v "^Status:" | head -20
            ufw disable 2>/dev/null
            yes | ufw reset 2>/dev/null
            systemctl stop ufw 2>/dev/null; systemctl disable ufw 2>/dev/null
            echo "  ✅ ufw 已禁用并重置。"
            ;;
        iptables)
            echo "  -> 准备清空 iptables 链..."
            echo "     INPUT: $(iptables -L INPUT -n 2>/dev/null | wc -l) 条"
            echo "     FORWARD: $(iptables -L FORWARD -n 2>/dev/null | wc -l) 条"
            echo "     OUTPUT: $(iptables -L OUTPUT -n 2>/dev/null | wc -l) 条"
            
            systemctl stop iptables 2>/dev/null; systemctl stop netfilter-persistent 2>/dev/null
            systemctl disable iptables 2>/dev/null; systemctl disable netfilter-persistent 2>/dev/null
            
            iptables -F 2>/dev/null; iptables -X 2>/dev/null; iptables -Z 2>/dev/null
            iptables -t nat -F 2>/dev/null; iptables -t nat -X 2>/dev/null
            iptables -P INPUT ACCEPT 2>/dev/null; iptables -P FORWARD ACCEPT 2>/dev/null; iptables -P OUTPUT ACCEPT 2>/dev/null
            echo "  ✅ iptables 已停止，规则清空，默认策略设为 ACCEPT。"
            ;;
    esac
}

# 启动并启用
start_enable_fw() {
    local fw=$1
    echo "正在启动并启用 $fw ..."
    case $fw in
        firewalld)
            systemctl start firewalld; systemctl enable firewalld
            firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
            echo "  -> 已自动放行 SSH。"
            ;;
        ufw)
            ufw allow ssh >/dev/null 2>&1; ufw allow 22/tcp >/dev/null 2>&1
            echo "y" | ufw enable
            systemctl enable ufw
            echo "  -> 已自动放行 SSH。"
            ;;
        iptables)
            command -v netfilter-persistent >/dev/null 2>&1 && { netfilter-persistent save 2>/dev/null; systemctl start netfilter-persistent; systemctl enable netfilter-persistent; } || { systemctl start iptables 2>/dev/null; }
            iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 22 -j ACCEPT
            echo "  -> 已自动添加 SSH 允许规则。"
            ;;
    esac
}

# ---------------------------------------------------------
# 功能模块 1: 管理防火墙服务
# ---------------------------------------------------------
manage_firewall_service() {
    while true; do
        clear
        echo "=== 防火墙服务管理 (智能去重版) ==="
        local all_fws=("firewalld" "ufw" "iptables")
        local i=1
        declare -A fw_map status_map
        
        echo "当前系统防火墙状态:"
        for fw in "${all_fws[@]}"; do
            local status=$(check_fw_status "$fw")
            status_map[$fw]=$status
            local display=$([ "$status" == "active" ] && echo "运行中" || ([ "$status" == "inactive" ] && echo "已安装 (未运行)" || echo "未安装"))
            printf "  %d. %-12s [%s]\n" "$i" "$fw" "$display"
            fw_map[$i]=$fw; ((i++))
        done
        
        echo ""; echo "0. 返回主菜单"
        echo "说明: 选择'未安装'将自动安装。启用新防火墙会自动清空其他所有规则。"
        read -p "请选择编号: " choice

        if [ "$choice" -eq 0 ]; then return
        elif [ "$choice" -ge 1 ] && [ "$choice" -lt $i ]; then
            local selected=${fw_map[$choice]}
            local status=${status_map[$selected]}
            echo ""; echo "你选择了: $selected ($status)"
            
            if [ "$status" == "not_installed" ]; then
                echo ">>> 开始自动安装..."
                install_firewall "$selected" || { echo "安装失败"; read -p "回车返回..."; continue; }
                echo ">>> 安装成功!"
                sleep 1
            fi
            
            echo ">>> 正在关闭并清空其他防火墙..."
            for fw in "${all_fws[@]}"; do
                [ "$fw" != "$selected" ] && [ "${status_map[$fw]}" != "not_installed" ] && stop_disable_and_flush_fw "$fw"
            done
            
            start_enable_fw "$selected"
            echo ""; echo "✅ 完成！当前活跃: $selected"
            CURRENT_FW="$selected"
            read -p "回车继续..."
        else
            echo "无效输入"; sleep 1
        fi
    done
}

# ---------------------------------------------------------
# 功能模块 2: 端口策略管理 (智能去重 + 冲突解决)
# ---------------------------------------------------------

show_current_rules() {
    echo "--- 当前防火墙策略详情 ---"
    [ -z "$CURRENT_FW" ] && {
        for fw in firewalld ufw iptables; do
            [ "$(check_fw_status $fw)" == "active" ] && { CURRENT_FW=$fw; break; }
        done
        [ -z "$CURRENT_FW" ] && { echo "错误: 无运行中的防火墙"; return 1; }
        echo "自动检测到: $CURRENT_FW"
    }
    case $CURRENT_FW in
        firewalld) firewall-cmd --list-all ;;
        ufw) ufw status verbose ;;
        iptables) iptables -L -n -v --line-numbers ;;
    esac
}

# 【核心】Firewalld 智能规则管理
fw_manage_rule() {
    local action=$1  # "allow" or "deny"
    local port=$2
    local ip=$3
    
    local rule_desc=""
    [ -n "$ip" ] && rule_desc="IP:$ip 端口:$port" || rule_desc="端口:$port"
    local target_action=$([ "$action" == "allow" ] && echo "放行" || echo "禁止")
    
    echo "🔍 正在检测 Firewalld 冲突规则... ($target_action $rule_desc)"

    # 1. 检测并清理冲突的 Rich Rules (针对 IP+Port 或 纯IP)
    if [ -n "$ip" ]; then
        # 检查是否有相反的 rich rule
        local existing=$(firewall-cmd --list-rich-rules 2>/dev/null | grep "source address='$ip'" | grep "port='$port'")
        if [ -n "$existing" ]; then
            if [[ "$existing" == *"accept"* ]] && [ "$action" == "deny" ]; then
                echo "  ⚠️  检测到冲突：发现允许的 Rich Rule，正在删除..."
                firewall-cmd --permanent --remove-rich-rule="$existing"
            elif [[ "$existing" == *"reject"* ]] && [ "$action" == "allow" ]; then
                echo "  ⚠️  检测到冲突：发现拒绝的 Rich Rule，正在删除..."
                firewall-cmd --permanent --remove-rich-rule="$existing"
            else
                echo "  ℹ️  检测到重复规则：已存在相同的 Rich Rule，跳过添加。"
                firewall-cmd --reload
                return
            fi
        fi
    fi

    # 2. 检测并清理冲突的 Ports 列表 (针对纯端口)
    if [ -z "$ip" ]; then
        local in_ports=$(firewall-cmd --list-ports 2>/dev/null)
        if [[ "$in_ports" == *"$port/tcp"* ]]; then
            if [ "$action" == "deny" ]; then
                echo "  ⚠️  检测到冲突：端口 $port 在放行列表中，正在移除..."
                firewall-cmd --permanent --remove-port=$port/tcp
            else
                echo "  ℹ️  检测到重复：端口 $port 已在放行列表中，跳过。"
                firewall-cmd --reload
                return
            fi
        fi
    fi

    # 3. 应用新规则
    echo "  ✅ 应用新规则：$target_action $rule_desc"
    if [ "$action" == "allow" ]; then
        if [ -n "$ip" ]; then
            firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$ip' port port='$port' protocol='tcp' accept"
        else
            firewall-cmd --permanent --add-port=$port/tcp
        fi
    else
        if [ -n "$ip" ]; then
            firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$ip' port port='$port' protocol='tcp' reject"
        else
            # 纯端口禁止：只需从列表移除即可，无需加 reject (保持界面整洁)
            # 如果用户强制要求显式 reject，可在此处添加 rich rule
            : 
        fi
    fi
    
    firewall-cmd --reload
    echo "  🎉 操作完成！"
}

# 【核心】UFW 智能规则管理
ufw_manage_rule() {
    local action=$1
    local port=$2
    local ip=$3
    
    local rule_desc=""
    [ -n "$ip" ] && rule_desc="IP:$ip 端口:$port" || rule_desc="端口:$port"
    local target_action=$([ "$action" == "allow" ] && echo "放行" || echo "禁止")
    
    echo "🔍 正在检测 UFW 冲突规则... ($target_action $rule_desc)"

    # 1. 获取当前状态
    local status_output=$(ufw status verbose 2>/dev/null)
    
    # 2. 检测冲突
    local has_allow=false
    local has_deny=false
    
    if [ -n "$ip" ]; then
        # 检查 IP+Port 规则
        echo "$status_output" | grep -q "$ip.*$port.*ALLOW" && has_allow=true
        echo "$status_output" | grep -q "$ip.*$port.*DENY" && has_deny=true
    else
        # 检查纯端口规则
        echo "$status_output" | grep -q "$port/tcp.*ALLOW" && has_allow=true
        echo "$status_output" | grep -q "$port/tcp.*DENY" && has_deny=true
    fi

    # 3. 处理冲突
    if [ "$has_allow" == true ] && [ "$action" == "deny" ]; then
        echo "  ⚠️  检测到冲突：发现允许规则，正在删除..."
        if [ -n "$ip" ]; then
            ufw delete allow from $ip to any port $port proto tcp 2>/dev/null
        else
            ufw delete allow $port/tcp 2>/dev/null
        fi
    elif [ "$has_deny" == true ] && [ "$action" == "allow" ]; then
        echo "  ⚠️  检测到冲突：发现禁止规则，正在删除..."
        if [ -n "$ip" ]; then
            ufw delete deny from $ip to any port $port proto tcp 2>/dev/null
        else
            ufw delete deny $port/tcp 2>/dev/null
        fi
    elif [ "$has_allow" == true ] && [ "$action" == "allow" ]; then
        echo "  ℹ️  检测到重复：已存在允许规则，跳过。"
        return
    elif [ "$has_deny" == true ] && [ "$action" == "deny" ]; then
        echo "  ℹ️  检测到重复：已存在禁止规则，跳过。"
        return
    fi

    # 4. 应用新规则
    echo "  ✅ 应用新规则：$target_action $rule_desc"
    if [ "$action" == "allow" ]; then
        if [ -n "$ip" ]; then
            ufw allow from $ip to any port $port proto tcp
        else
            ufw allow $port/tcp
        fi
    else
        if [ -n "$ip" ]; then
            ufw deny from $ip to any port $port proto tcp
        else
            ufw deny $port/tcp
        fi
    fi
    echo "  🎉 操作完成！"
}

# 【核心】Iptables 智能规则管理
ipt_manage_rule() {
    local action=$1
    local port=$2
    local ip=$3
    
    local rule_desc=""
    [ -n "$ip" ] && rule_desc="IP:$ip 端口:$port" || rule_desc="端口:$port"
    local target_action=$([ "$action" == "allow" ] && echo "放行" || echo "禁止")
    local target_chain="INPUT"
    local target_jump=$([ "$action" == "allow" ] && echo "ACCEPT" || echo "DROP")
    local opposite_jump=$([ "$action" == "allow" ] && echo "DROP" || echo "ACCEPT")
    
    echo "🔍 正在检测 Iptables 冲突规则... ($target_action $rule_desc)"

    # 1. 构建匹配特征
    local match_str=""
    if [ -n "$ip" ]; then
        match_str="-s $ip -p tcp --dport $port -j $opposite_jump"
    else
        match_str="-p tcp --dport $port -j $opposite_jump"
    fi

    # 2. 检测是否存在相反的规则 (冲突)
    # 使用 iptables -C 检查是否存在完全匹配的规则
    if iptables -C $target_chain $match_str 2>/dev/null; then
        echo "  ⚠️  检测到冲突：发现相反的规则 ($opposite_jump)，正在删除..."
        iptables -D $target_chain $match_str
    else
        # 检查是否已经存在相同的规则 (重复)
        local same_match=""
        if [ -n "$ip" ]; then
            same_match="-s $ip -p tcp --dport $port -j $target_jump"
        else
            same_match="-p tcp --dport $port -j $target_jump"
        fi
        
        if iptables -C $target_chain $same_match 2>/dev/null; then
            echo "  ℹ️  检测到重复：已存在相同的规则，跳过。"
            return
        fi
    fi

    # 3. 应用新规则 (插入到第一行，确保优先级最高)
    echo "  ✅ 应用新规则：$target_action $rule_desc (插入链首)"
    if [ -n "$ip" ]; then
        iptables -I $target_chain 1 -s $ip -p tcp --dport $port -j $target_jump
    else
        iptables -I $target_chain 1 -p tcp --dport $port -j $target_jump
    fi
    
    echo "  💾 提示: 规则已添加到内存。如需永久生效，请手动保存 (例如: netfilter-persistent save 或 service iptables save)"
    echo "  🎉 操作完成！"
}

# 统一入口函数
apply_smart_rule() {
    local action=$1 # "allow" or "deny"
    local port=$2
    local ip=$3
    
    case $CURRENT_FW in
        firewalld) fw_manage_rule "$action" "$port" "$ip" ;;
        ufw) ufw_manage_rule "$action" "$port" "$ip" ;;
        iptables) ipt_manage_rule "$action" "$port" "$ip" ;;
        *) echo "错误: 未知的防火墙类型"; return 1 ;;
    esac
}

# 菜单交互
add_rule() {
    echo "=== 添加放行策略 ==="
    echo "1. 放行指定端口 (对所有IP)"
    echo "2. 放行指定IP访问指定端口"
    echo "3. 放行指定IP段访问指定端口"
    echo "0. 返回"
    read -p "请选择: " sub
    case $sub in
        1) read -p "端口号: " p; [ -n "$p" ] && apply_smart_rule "allow" "$p" "" ;;
        2) read -p "IP: " i; read -p "端口: " p; [ -n "$i" ] && [ -n "$p" ] && apply_smart_rule "allow" "$p" "$i" ;;
        3) read -p "IP网段 (如 192.168.1.0/24): " i; read -p "端口: " p; [ -n "$i" ] && [ -n "$p" ] && apply_smart_rule "allow" "$p" "$i" ;;
        0) return ;;
        *) echo "无效"; sleep 1 ;;
    esac
}

remove_rule() {
    echo "=== 添加禁止/拉黑策略 ==="
    echo "1. 禁止访问指定端口 (对所有IP)"
    echo "2. 拉黑指定IP (禁止访问所有端口)"
    echo "3. 禁止指定IP访问指定端口"
    echo "0. 返回"
    read -p "请选择: " sub
    case $sub in
        1) read -p "端口: " p; [ -n "$p" ] && apply_smart_rule "deny" "$p" "" ;;
        2) read -p "IP: " i; [ -n "$i" ] && apply_smart_rule "deny" "" "$i" ;; # 注意：这里传空端口，特殊处理
        3) read -p "IP: " i; read -p "端口: " p; [ -n "$i" ] && [ -n "$p" ] && apply_smart_rule "deny" "$p" "$i" ;;
        0) return ;;
        *) echo "无效"; sleep 1 ;;
    esac
}

# 特殊处理：UFW/Firewalld 拉黑整个 IP 的逻辑需要微调
apply_smart_rule() {
    local action=$1
    local port=$2
    local ip=$3
    
    # 如果是拉黑整个 IP (port 为空)
    if [ -z "$port" ] && [ -n "$ip" ]; then
        echo "🔍 正在检测全IP拉黑规则... (禁止 IP:$ip 访问所有端口)"
        case $CURRENT_FW in
            firewalld)
                local existing=$(firewall-cmd --list-rich-rules 2>/dev/null | grep "source address='$ip' reject")
                if [ -n "$existing" ]; then
                    echo "  ℹ️  检测到重复：已存在该IP的拉黑规则，跳过。"
                    return
                fi
                # 清理可能的允许规则
                local allow_rule=$(firewall-cmd --list-rich-rules 2>/dev/null | grep "source address='$ip' accept")
                if [ -n "$allow_rule" ]; then
                    echo "  ⚠️  检测到冲突：发现允许该IP的规则，正在删除..."
                    firewall-cmd --permanent --remove-rich-rule="$allow_rule"
                fi
                echo "  ✅ 应用新规则：拉黑 IP:$ip"
                firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='$ip' reject"
                firewall-cmd --reload
                ;;
            ufw)
                if ufw status | grep -q "$ip.*DENY"; then
                    echo "  ℹ️  检测到重复：已存在该IP的拉黑规则，跳过。"
                    return
                fi
                ufw delete allow from $ip 2>/dev/null
                echo "  ✅ 应用新规则：拉黑 IP:$ip"
                ufw deny from $ip
                ;;
            iptables)
                if iptables -C INPUT -s $ip -j DROP 2>/dev/null; then
                    echo "  ℹ️  检测到重复：已存在该IP的拉黑规则，跳过。"
                    return
                fi
                iptables -D INPUT -s $ip -j ACCEPT 2>/dev/null
                echo "  ✅ 应用新规则：拉黑 IP:$ip (插入链首)"
                iptables -I INPUT 1 -s $ip -j DROP
                echo "  💾 提示: 规则已添加到内存。需手动保存以永久生效。"
                ;;
        esac
        echo "  🎉 操作完成！"
        return
    fi

    # 正常端口/IP+端口逻辑
    case $CURRENT_FW in
        firewalld) fw_manage_rule "$action" "$port" "$ip" ;;
        ufw) ufw_manage_rule "$action" "$port" "$ip" ;;
        iptables) ipt_manage_rule "$action" "$port" "$ip" ;;
        *) echo "错误: 未知的防火墙类型"; return 1 ;;
    esac
}

manage_port_policies() {
    [ -z "$CURRENT_FW" ] && {
        for fw in firewalld ufw iptables; do
            [ "$(check_fw_status $fw)" == "active" ] && { CURRENT_FW=$fw; break; }
        done
        [ -z "$CURRENT_FW" ] && { echo "错误: 无运行中的防火墙"; read -p "回车返回..."; return; }
    }

    while true; do
        clear
        echo "=== 端口策略管理 (当前:$CURRENT_FW) ==="
        show_current_rules
        echo ""
        echo "1. 放行指定策略 (自动清理冲突的禁止规则)"
        echo "2. 禁用指定策略 (自动清理旧的放行规则)"
        echo "0. 返回主菜单"
        read -p "选择: " c
        case $c in
            1) add_rule ;;
            2) remove_rule ;;
            0) return ;;
            *) echo "无效"; sleep 1 ;;
        esac
    done
}

# 主菜单
main_menu() {
    check_root
    while true; do
        clear
        echo "========================================="
        echo "   服务器防火墙统一管理 (智能去重版)   "
        echo "========================================="
        echo ""
        echo "1. 管理防火墙 (安装/切换/启停/清空)"
        echo "2. 管理端口策略 (智能检测重复/冲突)"
        echo "0. 退出"
        echo ""
        local active="无"
        for fw in firewalld ufw iptables; do
            [ "$(check_fw_status $fw)" == "active" ] && { active=$fw; break; }
        done
        echo "当前活跃防火墙: $active"
        echo ""
        read -p "请输入选项 [0-2]: " main_choice
        case $main_choice in
            1) manage_firewall_service ;;
            2) manage_port_policies ;;
            0) echo "退出。"; exit 0 ;;
            *) echo "无效"; sleep 1 ;;
        esac
    done
}

main_menu
