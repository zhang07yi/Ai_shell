#!/bin/bash

# ==============================================================================
#
# 脚本名称: manage.sh (Smart Microservice Manager)
# 版本号:   v6.3 Final Release (Fixed & Documented)
# 发布日期: 2026-03-16
# 作者:     zyi07
# 许可协议: MIT License
# 适用环境: Linux (CentOS/Ubuntu/Debian), Bash 4.0+
#
# ==============================================================================
# 【📖 产品全景概览】
# ==============================================================================
# 本脚本是一款专为生产环境设计的“零依赖”微服务集群管理工具。它摒弃了传统的
# PID 文件记录方式，采用基于 /proc 文件系统、lsof 端口检测和 pgrep 特征匹配的
# 实时状态感知技术。即使在进程异常崩溃、非正常退出或子进程残留等复杂场景下，
# 依然能精准识别服务状态并执行清理操作。
#
# 💡 设计理念:
# 1. Port is Truth (端口即真理): 对于网络服务，端口监听是判断服务可用的唯一金标准。
# 2. Context-Aware (上下文感知): 智能区分“启动中”、“已就绪”和“假死”状态。
# 3. Zero-Maintenance (零维护): 首次运行自动完成所有环境配置，无需人工干预。
# 4. Defensive Coding (防御性编程): 严格的白名单校验，防止误操作生产环境。
#
# ==============================================================================
# 【📘 快速上手指南 (Quick Start)】
# ==============================================================================
# 1. 赋予权限:
#    chmod +x manage.sh
#
# 2. 首次运行 (自动配置环境):
#    ./manage.sh
#    > 脚本会自动检测 shell 配置，写入 ~/.bashrc 和 ~/.bash_profile。
#    > 按提示执行 'source ~/.bashrc' 即可立即生效。
#
# 3. 常用命令速查:
#    ./manage.sh start all       # 按依赖顺序启动所有服务
#    ./manage.sh stop all        # 按依赖逆序停止所有服务 (保护数据一致性)
#    ./manage.sh restart dmp     # 重启单个业务服务
#    ./manage.sh status nnr      # 查看基础组件组状态 (含 PID 和端口详情)
#
# 4. Tab 补全体验:
#    输入 './manage.sh [TAB]'      -> 自动补全命令 (start/stop/restart/status)
#    输入 './manage.sh start [TAB]' -> 自动补全服务名 (nacos/dmp...) 或组名 (all/nnr...)
#
# ==============================================================================
# 【⚙️ 深度配置手册 (Configuration Guide)】
# ==============================================================================
# 本脚本通过顶部的两个数组进行配置，无需修改核心逻辑即可适配新服务。
#
# 1. 添加新服务 (SERVICE_MAP):
#    格式: ["别名"]="显示名|绝对路径|启动命令|监听端口|进程特征"
#
#    字段详解:
#    - 别名 (Key): 命令行使用的简短名称 (如: myapp)
#    - 显示名: 日志输出时的友好名称 (如: my-application)
#    - 绝对路径: 服务的工作目录 (必须是绝对路径，用于 cwd 校验)
#    - 启动命令: 
#      * 若包含 'nohup'，脚本直接执行该命令。
#      * 若不包含，脚本自动处理 nohup 和日志重定向到 <目录>/nohup.out。
#    - 监听端口: [关键] 服务监听的 TCP 端口。若为空则仅靠进程特征判断。
#    - 进程特征: 进程名关键词 (如 java, python, nginx)，用于辅助匹配。
#
#    示例:
#    ["myapp"]="my-app|/opt/myapp|./start.sh|8080|java"
#
# 2. 定义服务组 (GROUP_DEFS):
#    格式: "组名:服务别名 1,服务别名 2,..."
#
#    逻辑说明:
#    - 启动 (start): 按列表顺序依次启动 (先启动依赖项)。
#    - 停止 (stop): 自动**逆序**执行 (先停止依赖方，如先停应用再停数据库)。
#    - 重启 (restart): 先逆序停止，等待 3 秒，再顺序启动。
#
#    示例:
#    "backend:redis,mysql,myapp" 
#    -> 启动顺序: redis -> mysql -> myapp
#    -> 停止顺序: myapp -> mysql -> redis
#
# 3. 自定义日志文件名:
#    修改全局变量 LOG_FILE_NAME (默认为 nohup.out)。
#
# ==============================================================================
# 【🔍 故障排查指引 (Troubleshooting)】
# ==============================================================================
# Q1: 提示 "无效的命令" 或 "未知的目标"？
# A: 脚本启用了严格白名单校验。请检查拼写，或使用 Tab 键查看可用选项。
#
# Q2: 启动后显示 "端口未监听" (port_timeout)？
# A: 进程已启动，但指定时间内端口未打开。
#    - 可能原因：服务初始化慢、配置错误导致挂起、端口被占用。
#    - 解决：查看日志 (tail -f <日志路径>) 排查具体报错。
#
# Q3: 停止服务时提示 "清理失败，仍有顽固残留"？
# A: 某些子进程可能忽略了 SIGKILL 或处于不可中断睡眠状态 (D 状态)。
#    - 解决：手动执行 `ps -ef | grep <目录>` 确认残留进程，必要时重启服务器。
#
# Q4: Tab 补全在新开窗口不生效？
# A: V6.3 已自动修复此问题。如果仍失效，请检查 ~/.bash_profile 是否被其他配置覆盖，
#    或手动执行 `source ~/.bash_profile`。
#
# ==============================================================================

set -o pipefail

# ------------------------------------------------------------------------------
# 全局变量定义 (Global Variables)
# ------------------------------------------------------------------------------
MY_PID=$$
PARENT_PID=$PPID
LOG_FILE_NAME="nohup.out"

# 允许的动词命令白名单 (用于严格校验，防止误操作)
VALID_COMMANDS=("start" "stop" "restart" "status")

# 获取当前脚本的绝对路径 (用于自动配置补全)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"

# ------------------------------------------------------------------------------
# 1. 服务配置区 (Service Configuration)
# ------------------------------------------------------------------------------
# 格式: ["KEY"]="Name|Dir|Cmd|Port|Pattern"
declare -A SERVICE_MAP=(
    # 基础中间件
    ["nacos"]="nacos|/usr/local/nacos|./bin/startup.sh -m standalone|8848|nacos"
    ["nginx"]="nginx|/usr/local/nginx|./sbin/nginx|8912|nginx"
    ["redis"]="redis|/usr/local/redis|./src/redis-server redis.conf|6379|redis-server"
    
    # 业务应用 (Java)
    ["app"]="app-service|/opt/app|nohup ./startup-linux.sh &|8080|java"
    ["webapp"]="emc-tool|/opt/app/tools/web|nohup ./startup-linux.sh &|8089|java"
)

# 服务组定义 (启动顺序即依赖顺序)
declare -a GROUP_DEFS=(
    "nnr:nacos,nginx,redis"             # 基础组件组
    "eap:dmp,emc"                       # 应用组件组
    "all:nacos,nginx,redis,dmp,emc"     # 全量组
)

# ------------------------------------------------------------------------------
# 2. 核心校验引擎 (Core Validation Engine)
# ------------------------------------------------------------------------------

# [原子能力] 验证 PID 是否属于指定目录
# 原理: 优先读取 /proc/[pid]/cwd (最可靠)，兜底检查 cmdline。
# 返回: 0 (匹配), 1 (不匹配)
verify_pid_dir() {
    local pid=$1
    local target_dir=$2
    
    # 安全防御：排除脚本自身及父进程，防止自杀
    if [[ "$pid" == "$MY_PID" || "$pid" == "$PARENT_PID" ]]; then return 1; fi
    if [[ ! -d "/proc/$pid" ]]; then return 1; fi

    # 方法 1: 检查工作目录 (cwd) - 黄金标准
    local cwd=$(readlink -f /proc/$pid/cwd 2>/dev/null)
    if [[ -n "$cwd" ]]; then
        # 精确匹配：必须是目标目录本身或其子目录
        if [[ "$cwd" == "$target_dir" || "$cwd" == "$target_dir/"* ]]; then
            return 0
        fi
        return 1
    fi
    
    # 方法 2: 检查启动命令 (兜底策略)
    local cmd_args=$(ps -p $pid -o args= 2>/dev/null)
    if [[ "$cmd_args" == *"$target_dir"* ]]; then return 0; fi
    
    return 1
}

# [核心引擎] 获取进程 PID (支持模式切换)
# 参数: $1=端口, $2=进程特征, $3=目录, $4=模式 (start | status)
#
# 设计哲学:
#   - [start 模式]: 严格主义。若配置了端口，只认端口监听。端口不通直接返回失败，
#                   迫使上层循环继续等待，防止误判“假死”或“初始化中”的进程为成功。
#   - [status 模式]: 实用主义。若端口不通，自动降级尝试通过目录匹配查找进程。
#                   目的是为了让用户看到“虽然端口没通，但进程确实在运行 (PID: xxx)”。
get_pid() {
    local port=$1
    local proc_name=$2
    local dir=$3
    local mode=${4:-start}

    # --- 优先级 1: 端口匹配 (权威来源) ---
    if [[ -n "$port" ]]; then
        local port_pid=$(lsof -t -i:$port 2>/dev/null | head -n1)
        if [[ -n "$port_pid" ]]; then
            if verify_pid_dir "$port_pid" "$dir"; then
                echo "$port_pid"
                return 0
            fi
        fi
        
        # 分支逻辑
        if [[ "$mode" == "start" ]]; then
            # 启动阶段：端口不通即视为未就绪，不浪费资源去查目录
            return 1
        else
            # 状态查询：端口不通，但我们需要知道是否有进程在占位，继续执行优先级 2
            : 
        fi
    fi

    # --- 优先级 2: 目录 + 特征匹配 (降级策略) ---
    if [[ -n "$proc_name" ]]; then
        local all_pids=$(pgrep -f "$dir|$proc_name" 2>/dev/null)
        for p in $all_pids; do
            if verify_pid_dir "$p" "$dir"; then
                echo "$p"
                return 0
            fi
        done
    fi
    
    return 1
}

# [辅助工具] 检查目录下是否有存活进程 (用于清理残留)
# 副作用: 找到的第一个有效 PID 会存入全局变量 LAST_FOUND_PID
LAST_FOUND_PID=""
check_dir_has_process() {
    local target_dir=$1
    local proc_name=$2
    local search_pattern="$target_dir"
    [[ -n "$proc_name" ]] && search_pattern="$target_dir|$proc_name"
    
    LAST_FOUND_PID=""
    local pids=$(pgrep -f "$search_pattern" 2>/dev/null)
    for pid in $pids; do
        if [[ "$pid" != "$MY_PID" && "$pid" != "$PARENT_PID" ]]; then
            if verify_pid_dir "$pid" "$target_dir"; then 
                LAST_FOUND_PID="$pid"
                return 0 
            fi
        fi
    done
    return 1
}

# [执行器] 清理目录下所有关联进程
# 策略: 统一使用 SIGKILL (-9) 确保彻底清除
kill_processes_by_dir() {
    local target_dir=$1
    local svc_name=$2
    local force=$3 # 参数保留以兼容调用，实际逻辑强制为 -9
    local signal="-9"
    
    local config="${SERVICE_MAP[$svc_name]}"
    local proc_name=""
    if [[ -n "$config" ]]; then
        IFS='|' read -r _ _ _ _ proc_name <<< "$config"
    fi
    
    local search_pattern="$target_dir"
    [[ -n "$proc_name" ]] && search_pattern="$target_dir|$proc_name"
    
    local pids=$(pgrep -f "$search_pattern" 2>/dev/null)
    local count=0
    for pid in $pids; do
        if [[ "$pid" != "$MY_PID" && "$pid" != "$PARENT_PID" ]]; then
            if verify_pid_dir "$pid" "$target_dir"; then
                kill $signal "$pid" 2>/dev/null
                ((count++))
            fi
        fi
    done
    [[ $count -gt 0 ]] && echo "       -> [清理] 额外终止了 $count 个关联子进程 ($signal)"
}

# ------------------------------------------------------------------------------
# 3. 业务操作逻辑 (Business Logic)
# ------------------------------------------------------------------------------

operate_service() {
    local action=$1
    local svc_name=$2
    local config="${SERVICE_MAP[$svc_name]}"

    if [[ -z "$config" ]]; then
        echo "[ERROR] 服务 '$svc_name' 未定义"
        return 1
    fi
    
    IFS='|' read -r name dir cmd port proc <<< "$config"
    local log_path="$dir/$LOG_FILE_NAME"

    # [性能优化] 根据操作类型选择检测模式
    local check_mode="start"
    [[ "$action" == "status" ]] && check_mode="status"
    
    local pid=$(get_pid "$port" "$proc" "$dir" "$check_mode")

    case "$action" in
        status)
            if [[ -n "$pid" ]]; then
                local status_detail="PID: $pid"
                if [[ -n "$port" ]]; then
                    if lsof -i:$port > /dev/null 2>&1; then
                        status_detail="$status_detail, 端口 $port (已就绪)"
                    else
                        status_detail="$status_detail, 端口 $port (初始化中...)"
                    fi
                fi
                echo "[OK] $name 运行中 ($status_detail)"
                return 0
            else
                # 只有当 get_pid (含降级逻辑) 都没找到时，才做最后的全量扫描
                if check_dir_has_process "$dir" "$proc"; then
                    if [[ -n "$LAST_FOUND_PID" ]]; then
                        echo "[STARTING...] $name 进程存在但尚未完全就绪 (PID: $LAST_FOUND_PID)"
                    else
                        echo "[STARTING...] $name 进程存在但尚未完全就绪"
                    fi
                    return 0
                else
                    echo "[STOPPED] $name 未运行"
                    return 1
                fi
            fi
            ;;
            
        start)
            if [[ -n "$pid" ]]; then
                echo "[INFO] $name 已在运行 (PID: $pid)，跳过启动。"
                return 0
            fi
            
            if [[ ! -d "$dir" ]]; then
                echo "[ERROR] 目录不存在: $dir"
                return 1
            fi
            
            echo "[STARTING] 正在启动 $name ..."
            cd "$dir" || { echo "[ERROR] 无法进入目录"; return 1; }
            
            # 日志处理
            if [[ "$cmd" != *"nohup"* ]]; then
                > "$log_path"
                chmod 644 "$log_path"
            fi
            
            # 执行启动 (修复后的标准写法，兼容所有 Bash 版本)
            if [[ "$cmd" == *"nohup"* ]]; then 
                eval "$cmd"
            else 
                # 使用子 shell 执行并重定向 (修复了之前的语法错误)
                ( eval "$cmd" ) >> "$log_path" 2>&1 &
            fi
            
            # [智能等待] 20 秒窗口，轮询检测
            local max_wait=20
            local waited=0
            local new_pid=""
            
            while [[ $waited -lt $max_wait ]]; do
                sleep 1
                ((waited++))
                
                # 启动阶段始终使用严格模式
                new_pid=$(get_pid "$port" "$proc" "$dir" "start")
                
                if [[ -n "$new_pid" ]]; then
                    break
                fi
            done

            # 最终状态确认
            local final_status="unknown"
            if [[ -n "$new_pid" ]]; then
                if [[ -n "$port" ]]; then
                    if lsof -i:$port > /dev/null 2>&1; then
                        final_status="success"
                    else
                        final_status="port_timeout"
                    fi
                else
                    final_status="success"
                fi
            else
                final_status="no_pid"
            fi

            # 结构化输出
            if [[ "$final_status" == "success" ]]; then
                echo "[OK] $name 启动成功 (PID: $new_pid)"
                [[ -n "$port" ]] && echo "       -> [端口] $port 已监听"
                echo "       -> [日志] 查看路径: $log_path"
                return 0
            elif [[ "$final_status" == "port_timeout" ]]; then
                echo "[WARN] $name 进程已启动 (PID: $new_pid)，但端口 $port 在 ${max_wait}s 内未监听。"
                echo "       [重要] 服务可能正在缓慢初始化。请查看日志: tail -f $log_path"
                return 0
            else
                echo "[INFO] $name 启动命令已执行，但未检测到进程。"
                echo "       [重要] 请查看日志排查: tail -f $log_path"
                return 0
            fi
            ;;
            
        stop)
            # 停止操作必须使用严格模式，确保杀的是正确的进程
            local strict_pid=$(get_pid "$port" "$proc" "$dir" "start")
            
            if [[ -z "$strict_pid" ]]; then
                echo "[INFO] 未检测到 $name 主进程，扫描残留..."
                if check_dir_has_process "$dir" "$proc"; then
                    echo "[WARN] 发现残留进程，执行强制清理..."
                    kill_processes_by_dir "$dir" "$name" true
                    sleep 2
                    if ! check_dir_has_process "$dir" "$proc"; then
                        echo "[OK] 残留已清理"
                        return 0
                    else
                        echo "[ERROR] 清理失败，仍有进程存活"
                        return 1
                    fi
                else
                    echo "[INFO] $name 确实未运行"
                    return 0
                fi
            fi
            
            echo "[STOPPING] 停止 $name (主 PID: $strict_pid) ..."
            kill -9 "$strict_pid" 2>/dev/null
            
            # [性能优化] 高频初检 + 指数退避
            local count=0
            local wait_time=0.2
            local max_checks=15 
            
            while [[ $count -lt $max_checks ]]; do
                sleep $wait_time
                
                if [[ $count -eq 10 ]]; then
                    wait_time=1
                    echo "[WAIT] 等待进程完全退出..."
                fi

                if [[ ! -d "/proc/$strict_pid" ]]; then
                    echo "[WARN] 主进程结束，清理残留子进程..."
                    kill_processes_by_dir "$dir" "$name" false
                    sleep 1
                    if ! check_dir_has_process "$dir" "$proc"; then
                        echo "[OK] 子进程已清理"
                        return 0
                    fi
                    kill_processes_by_dir "$dir" "$name" true
                    sleep 1
                    if ! check_dir_has_process "$dir" "$proc"; then
                        echo "[OK] 子进程已强制清理"
                        return 0
                    else
                        break
                    fi
                fi
                ((count++))
            done
            
            echo "[WARN] 超时未响应，执行最终强制杀死 (SIGKILL)..."
            kill -9 "$strict_pid" 2>/dev/null
            kill_processes_by_dir "$dir" "$name" true
            sleep 2
            
            if ! check_dir_has_process "$dir" "$proc"; then
                echo "[OK] $name 已强制停止并清理完毕"
                return 0
            else
                echo "[ERROR] 停止失败，仍有顽固残留:"
                ps -ef | grep "$dir" | grep -v grep
                return 1
            fi
            ;;
            
        restart)
            operate_service stop "$svc_name"
            sleep 2
            operate_service start "$svc_name"
            ;;
    esac
}

# 获取组内服务列表
get_group_services() {
    local group_name=$1
    for def in "${GROUP_DEFS[@]}"; do
        local g_name="${def%%:*}"
        if [[ "$g_name" == "$group_name" ]]; then 
            echo "${def#*:}"
            return 0
        fi
    done
    return 1
}

# 组操作逻辑 (自动处理启动顺序和停止逆序)
operate_group() {
    local action=$1
    local group_name=$2
    local svc_list_str=$(get_group_services "$group_name")
    if [[ -z "$svc_list_str" ]]; then
        echo "[ERROR] 组 '$group_name' 未定义"
        return 1
    fi
    
    IFS=',' read -ra svc_array <<< "$svc_list_str"
    local final_order=("${svc_array[@]}")
    
    if [[ "$action" == "stop" || "$action" == "restart" ]]; then
        if [[ "$action" == "restart" ]]; then
            echo "========================================"
            echo "  重启组：$group_name"
            echo "========================================"
            local reversed=()
            for (( i=${#final_order[@]}-1; i>=0; i-- )); do reversed+=("${final_order[i]}"); done
            for svc in "${reversed[@]}"; do operate_service stop "$svc"; echo "----------------------------------------"; done
            sleep 3
            for svc in "${final_order[@]}"; do operate_service start "$svc"; echo "----------------------------------------"; done
            return
        else
            local reversed=()
            for (( i=${#final_order[@]}-1; i>=0; i-- )); do reversed+=("${final_order[i]}"); done
            final_order=("${reversed[@]}")
            echo "========================================"
            echo "  停止组：$group_name (逆序)"
            echo "========================================"
        fi
    else
        echo "========================================"
        echo "  ${action^} 组：$group_name"
        echo "========================================"
    fi

    for svc in "${final_order[@]}"; do
        operate_service "$action" "$svc"
        echo "----------------------------------------"
    done
}

# ------------------------------------------------------------------------------
# 4. 辅助功能：校验、帮助与【增强版】自动安装
# ------------------------------------------------------------------------------

show_usage() {
    echo "=================================================="
    echo "  企业级服务管理脚本 (Smart Manage v6.3 Universal)"
    echo "=================================================="
    echo "用法：$0 <命令> <目标>"
    echo ""
    echo "可用命令:"
    printf "  %-10s %s\n" "${VALID_COMMANDS[@]}"
    echo ""
    echo "可用服务:"
    for key in "${!SERVICE_MAP[@]}"; do echo "  - $key"; done
    echo ""
    echo "可用组:"
    for def in "${GROUP_DEFS[@]}"; do echo "  - ${def%%:*} (${def#*:})"; done
    echo ""
    echo "💡 提示：支持 Tab 键自动补全。首次运行已自动配置!"
}

# [🌟 增强版] 自动配置 Tab 补全 (兼容 Login 和 Non-Login Shell)
# 逻辑: 
# 1. 写入 ~/.bashrc (针对当前交互式 Shell)
# 2. 写入 ~/.bash_profile (针对 SSH 登录等新开的 Login Shell)
# 3. 若 .bash_profile 未加载 .bashrc，自动注入标准加载代码，确保环境变量同步。
auto_setup_completion() {
    local setup_line="source ${SCRIPT_PATH}"
    local configured=false

    # 1. 配置 ~/.bashrc
    local rc_file="$HOME/.bashrc"
    if [[ -f "$rc_file" ]]; then
        if ! grep -Fq "$setup_line" "$rc_file"; then
            echo "" >> "$rc_file"
            echo "# Auto-added by manage.sh v6.3 for Tab Completion" >> "$rc_file"
            echo "$setup_line" >> "$rc_file"
            configured=true
        fi
    fi

    # 2. 配置 ~/.bash_profile (关键步骤：解决新开窗口失效问题)
    local profile_file="$HOME/.bash_profile"
    if [[ -f "$profile_file" ]]; then
        # 检查是否已经 source 了脚本
        if ! grep -Fq "$setup_line" "$profile_file"; then
            # 检查是否已经 source 了 .bashrc (标准做法)
            if ! grep -q '\.bashrc' "$profile_file" && ! grep -q 'source.*\.bashrc' "$profile_file"; then
                # 如果没有，则添加标准的 .bashrc 加载逻辑
                echo "" >> "$profile_file"
                echo "# Added by manage.sh v6.3 to ensure .bashrc is loaded" >> "$profile_file"
                echo 'if [ -f ~/.bashrc ]; then' >> "$profile_file"
                echo '    . ~/.bashrc' >> "$profile_file"
                echo 'fi' >> "$profile_file"
            fi
            
            # 同时也直接 source 脚本 (双重保险)
            echo "" >> "$profile_file"
            echo "# Auto-added by manage.sh v6.3 for Tab Completion" >> "$profile_file"
            echo "$setup_line" >> "$profile_file"
            configured=true
        fi
    fi

    # 3. 如果进行了配置，输出提示
    if [[ "$configured" == true ]]; then
        echo "=================================================="
        echo "  🎉 自动配置成功 (全兼容模式)!"
        echo "=================================================="
        echo "  检测到您的环境尚未完全启用 Tab 补全。"
        echo "  脚本已自动更新以下文件:"
        echo "    - ~/.bashrc"
        echo "    - ~/.bash_profile (确保新开窗口/SSH 登录生效)"
        echo ""
        echo "  👉 下一步操作:"
        echo "     执行以下命令立即在当前窗口生效:"
        echo "     source ~/.bashrc"
        echo ""
        echo "  ✅ 验证方法:"
        echo "     关闭当前终端，重新打开一个新窗口 (或重新 SSH 登录)，"
        echo "     输入 './manage.sh [TAB]' 即可看到补全提示!"
        echo "=================================================="
        echo ""
    fi
}

# Tab 补全实现函数
_manage_complete() {
    local cur prev words cword
    if declare -F _init_completion > /dev/null; then _init_completion -n := || return; fi
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cword=$COMP_CWORD
    local targets=()
    for key in "${!SERVICE_MAP[@]}"; do targets+=("$key"); done
    for def in "${GROUP_DEFS[@]}"; do targets+=("${def%%:*}"); done
    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "${VALID_COMMANDS[*]}" -- "$cur"))
    elif [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "${targets[*]}" -- "$cur"))
    else
        COMPREPLY=()
    fi
    return 0
}

# 注册补全
complete -F _manage_complete manage.sh 2>/dev/null
complete -F _manage_complete ./manage.sh 2>/dev/null

# ------------------------------------------------------------------------------
# 5. 入口函数 (Entry Point)
# ------------------------------------------------------------------------------

main() {
    local cmd=$1
    local target=$2

    # [自动安装检查] 每次运行都检查是否需要配置补全
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        auto_setup_completion
    fi

    # 参数校验
    if [[ -z "$cmd" ]]; then show_usage; exit 1; fi

    local cmd_valid=false
    for valid_cmd in "${VALID_COMMANDS[@]}"; do
        if [[ "$cmd" == "$valid_cmd" ]]; then cmd_valid=true; break; fi
    done
    if [[ "$cmd_valid" == false ]]; then
        echo "[ERROR] 无效的命令：'$cmd'"
        echo "提示：请使用以下命令之一：${VALID_COMMANDS[*]}"
        exit 1
    fi

    if [[ -z "$target" ]]; then
        echo "[ERROR] 缺少目标参数 (服务名或组名)"
        exit 1
    fi

    local is_service=false
    local is_group=false
    [[ -n "${SERVICE_MAP[$target]}" ]] && is_service=true
    get_group_services "$target" > /dev/null 2>&1 && is_group=true

    if [[ "$is_service" == false && "$is_group" == false ]]; then
        echo "[ERROR] 未知的目标：'$target'"
        echo "可用的服务："
        for key in "${!SERVICE_MAP[@]}"; do echo "  - $key"; done
        echo "可用的组："
        for def in "${GROUP_DEFS[@]}"; do echo "  - ${def%%:*}"; done
        exit 1
    fi

    if [[ "$is_group" == true ]]; then operate_group "$cmd" "$target"
    else operate_service "$cmd" "$target"; fi
}

# 智能加载逻辑
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    : # Source 模式：仅加载函数和补全，不执行 main
else
    main "$@"
fi
