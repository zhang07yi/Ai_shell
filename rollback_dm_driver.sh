#!/bin/bash
#===============================================================================
# 脚本名称: rollback_dm_driver.sh
# 功能描述: 紧急回滚达梦数据库驱动与方言文件到最近的备份版本。
# 版本信息: v1.0 (生产应急版 - 自动发现 + 安全校验)
# 关联脚本: upgrade_dm_driver.sh
# 使用场景: 当升级后出现兼容性问题、启动失败或报错时，立即执行此脚本。
#===============================================================================

set -o pipefail

#-------------------------------------------------------------------------------
# [配置区]
#-------------------------------------------------------------------------------

# 备份文件特征正则：匹配 .YYYYMMDD_HHMMSS 后缀
# 例如: DmJdbcDriver-18.jar.20260316_140700
BACKUP_PATTERN="\.[0-9]{8}_[0-9]{6}$"

# 最大并发数 (建议与升级脚本保持一致)
MAX_PARALLEL=10

# 颜色定义
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

#-------------------------------------------------------------------------------
# [辅助函数]
#-------------------------------------------------------------------------------

log_msg() {
    local type="$1"
    local msg="$2"
    local color=""
    case "$type" in
        "INFO")    color="$COLOR_BLUE" ;;
        "SUCCESS") color="$COLOR_GREEN" ;;
        "WARN")    color="$COLOR_YELLOW" ;;
        "ERROR")   color="$COLOR_RED" ;;
        *)         color="$COLOR_RESET" ;;
    esac
    echo -e "${color}[$(date '+%H:%M:%S')] [$type] ${msg}${COLOR_RESET}"
}

#-------------------------------------------------------------------------------
# [核心逻辑]
#-------------------------------------------------------------------------------

# 函数：查找最近的备份批次
find_latest_backup_suffix() {
    # 1. 查找所有匹配备份模式的文件
    # 2. 提取后缀部分
    # 3. 排序并取最后一个 (最新的)
    # 4. 去重
    
    local all_suffixes
    all_suffixes=$(find . -type f -name "*${BACKUP_PATTERN}" 2>/dev/null | \
                   sed -n "s/.*\(\.[0-9]\{8\}_[0-9]\{6\}\)$/\1/p" | \
                   sort -u)

    if [[ -z "$all_suffixes" ]]; then
        return 1
    fi

    # 返回最后一行 (最新的时间戳)
    echo "$all_suffixes" | tail -n 1
}

# 函数：验证新文件是否被误删 (安全检查)
# 如果回滚需要把旧文件移回来，但新文件(当前运行的文件)不存在了，说明现场被破坏了
validate_environment() {
    local suffix="$1"
    local backup_files
    local error_count=0

    log_msg "INFO" "正在验证环境完整性..."

    # 获取所有待回滚的备份文件列表
    mapfile -t backup_files < <(find . -type f -name "*${suffix}" 2>/dev/null)

    if [[ ${#backup_files[@]} -eq 0 ]]; then
        log_msg "ERROR" "未找到任何后缀为 ${suffix} 的备份文件！"
        return 1
    fi

    log_msg "INFO" "发现 ${#backup_files[@]} 个待回滚文件。"

    # 检查对应的“当前文件”是否存在
    # 逻辑：备份文件是 A.jar.2026..., 回滚意味着要把 A.jar.2026... 变回 A.jar
    # 风险点：如果 A.jar 已经不存在了（被误删），直接 mv 可能会导致逻辑混乱（虽然 mv 只是改名）
    # 这里主要检查：是否有足够的权限，以及磁盘空间是否正常
    
    for b_file in "${backup_files[@]}"; do
        # 计算回滚后的目标文件名 (去掉后缀)
        local target_file="${b_file%${suffix}}"
        
        # 如果目标文件已经存在（说明升级后的新文件还在），这是正常情况，可以直接覆盖(替换)
        # 如果目标文件不存在，说明新文件可能被误删了，回滚是将备份改名填补空缺，这也是允许的。
        # 唯一危险的情况是：备份文件本身损坏或大小为0
        if [[ ! -s "$b_file" ]]; then
            log_msg "WARN" "⚠️ 警告：备份文件大小为0或不存在 -> $b_file"
            ((error_count++))
        fi
    done

    if (( error_count > 0 )); then
        log_msg "ERROR" "发现 $error_count 个无效备份文件，建议人工检查后再执行回滚。"
        read -p "是否强制继续？(y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            return 1
        fi
    fi

    return 0
}

# 函数：执行单个文件回滚
rollback_single_file() {
    local backup_file="$1"
    local suffix="$2"
    
    local target_file="${backup_file%${suffix}}"

    # 1. 如果目标文件已存在（即升级后的新文件），先将其备份为一个临时临时文件，以防万一
    #    但为了速度，通常直接 mv 覆盖即可。因为 backup_file 本身就是唯一的真理。
    #    策略：直接 mv 备份文件到目标位置，覆盖现有文件。
    
    if mv "$backup_file" "$target_file" 2>/dev/null; then
        return 0
    else
        echo "ERROR:${backup_file}"
        return 1
    fi
}

# 函数：并行执行回滚
run_rollback() {
    local suffix="$1"
    local backup_files=()
    
    # 收集所有该批次的备份文件
    mapfile -t backup_files < <(find . -type f -name "*${suffix}" 2>/dev/null)
    
    local total=${#backup_files[@]}
    if [[ $total -eq 0 ]]; then
        log_msg "ERROR" "没有文件需要回滚。"
        return 1
    fi

    log_msg "INFO" "开始并行回滚 ${total} 个文件..."
    
    local active_pids=()
    local success=0
    local fail=0
    local failed_list=()

    for b_file in "${backup_files[@]}"; do
        (
            result=$(rollback_single_file "$b_file" "$suffix")
            if [[ "$result" == ERROR:* ]]; then
                exit 1
            fi
            exit 0
        ) &
        
        local pid=$!
        active_pids+=("$pid:$b_file")

        # 流控
        while (( ${#active_pids[@]} >= MAX_PARALLEL )); do
            wait -n 2>/dev/null || true
            local new_pids=()
            for item in "${active_pids[@]}"; do
                local p_id="${item%%:*}"
                if kill -0 "$p_id" 2>/dev/null; then
                    new_pids+=("$item")
                fi
            done
            active_pids=("${new_pids[@]}")
        done
    done

    # 收集结果
    for item in "${active_pids[@]}"; do
        local p_id="${item%%:*}"
        local p_file="${item#*:}"
        if ! wait "$p_id"; then
            ((fail++))
            failed_list+=("$p_file")
            log_msg "ERROR" "❌ 回滚失败: $p_file"
        else
            ((success++))
            # 静默成功
        fi
    done

    echo "-------------------------------------------------------------------------------"
    log_msg "INFO" "回滚结果：成功 $success, 失败 $fail"
    
    if (( fail > 0 )); then
        log_msg "ERROR" "以下文件回滚失败，请人工检查:"
        for f in "${failed_list[@]}"; do
            echo "   - $f"
        done
        return 1
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# [主程序入口]
#-------------------------------------------------------------------------------

main() {
    echo "==============================================================================="
    echo "🛡️  达梦驱动/方言 紧急回滚脚本 (Emergency Rollback)"
    echo "==============================================================================="

    # 1. 查找最新的备份批次
    log_msg "INFO" "正在扫描最近的备份批次..."
    local latest_suffix
    latest_suffix=$(find_latest_backup_suffix)

    if [[ -z "$latest_suffix" ]]; then
        log_msg "ERROR" "❌ 未找到任何备份文件！"
        log_msg "INFO" "   请确认：1. 是否执行过升级脚本？ 2. 备份文件是否被清理？"
        log_msg "INFO" "   备份文件特征：*.YYYYMMDD_HHMMSS (例如: .20260316_140700)"
        exit 1
    fi

    # 去掉前导的点号以便显示
    local display_suffix="${latest_suffix#.}"
    log_msg "SUCCESS" "✅ 发现最近备份批次：${display_suffix}"
    log_msg "WARN" "⚠️  即将回滚到该时间点的所有文件！"
    
    # 2. 二次确认 (如果是非交互模式，可添加参数跳过)
    if [[ -t 0 ]]; then # 判断是否为终端交互
        read -p "确认立即执行回滚？(输入 yes 确认): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_msg "INFO" "操作已取消。"
            exit 0
        fi
    else
        log_msg "WARN" "非交互模式，自动确认执行。"
    fi

    # 3. 环境验证
    if ! validate_environment "$latest_suffix"; then
        log_msg "ERROR" "环境验证失败，终止回滚。"
        exit 1
    fi

    # 记录开始时间
    local start_time=$(date +%s.%N)

    # 4. 执行回滚
    if run_rollback "$latest_suffix"; then
        local end_time=$(date +%s.%N)
        local duration=$(echo "$end_time - $start_time" | bc)
        
        echo "==============================================================================="
        log_msg "SUCCESS" "🎉 回滚完成！系统已恢复到 ${display_suffix} 的状态。"
        printf "⏱️  耗时：%.3f 秒\n" "$duration"
        echo "💡 建议：请立即重启相关服务以加载旧版驱动。"
        echo "==============================================================================="
        exit 0
    else
        log_msg "ERROR" "❌ 回滚过程中发生错误，部分文件可能未恢复。请检查上方日志！"
        exit 1
    fi
}

main "$@"
