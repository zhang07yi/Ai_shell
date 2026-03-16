#!/bin/bash

# ==============================================================================
# 脚本名称：universal_cleaner.sh
# 版本号：v2.0 (Production Ready)
# 功能描述：企业级多策略文件/文件夹自动清理工具
#           1. FILE 模式：递归全量清理指定后缀的旧文件
#           2. FOLDER 模式：智能增量清理带日期命名的旧文件夹
#           3. 安全机制：双重校验（文件名日期 + 实际修改时间），防止误删
#           4. 自维护：自动清理脚本自身的历史运行日志
# 适用系统：CentOS 6+, Ubuntu 14+, Debian 7+ (兼容 Bash 3.x+)
# ==============================================================================

# ==============================================================================
# 【第一部分：全局配置】
# ==============================================================================

# 1. 脚本运行日志存储目录
#    建议：选择一个有写入权限、且不会被其他系统策略清理的目录
SCRIPT_LOG_DIR="/var/log/universal_cleaner_logs"

# 2. 脚本自身日志保留天数
#    说明：超过此天数的旧运行日志会被自动删除，防止日志堆积占满磁盘
SCRIPT_LOG_RETAIN_DAYS=15

# ==============================================================================
# 【第二部分：清理任务配置 (核心)】
# ==============================================================================
# 格式："模式 | 目标目录 | 保留天数 | 匹配规则 | 备用参数"
#
# 参数详解：
# 1. 模式 (Mode):
#    - FILE   : 全量文件清理。递归遍历目录下所有子文件夹。
#    - FOLDER : 增量文件夹清理。仅扫描一级子文件夹，根据文件名中的日期判断。
#
# 2. 目标目录 (Target Dir):
#    - 必须填写绝对路径。
#
# 3. 保留天数 (Retain Days):
#    - 整数。例如 7 表示保留最近 7 天，删除第 8 天及更早的数据。
#
# 4. 匹配规则 (Rule):
#    - [FILE 模式]: 文件后缀，空格分隔。例：".log .txt .gz"。留空表示删除所有文件。
#    - [FOLDER 模式]: 文件夹前缀，逗号分隔。例："YWXT,TZXT"。
#      * 设为 "*" 表示匹配该目录下所有包含有效日期的文件夹。
#
# 5. 备用参数: 目前预留，保持为空 "|" 即可。
# ==============================================================================

declare -a TASKS=(
    # --- 示例任务 1: 清理 Nginx 日志 (FILE 模式) ---
    # 逻辑：递归清理 /var/log/nginx 下所有 .log 和 .out 文件，保留 7 天
    "FILE|/var/log/nginx|7|.log .out|"

    # --- 示例任务 2: 清理业务数据文件夹 (FOLDER 模式) ---
    # 逻辑：清理 /data/business 下以 YWXT 或 TZXT 开头的文件夹，保留 7 天
    # 支持格式：YWXT20260316, YWXT-2026-03-16 等
    "FOLDER|/data/business|7|YWXT,TZXT|"

    # --- 示例任务 3: 清理通用备份 (FOLDER 通配模式) ---
    # 逻辑：清理 /data/backups 下所有能识别出日期的文件夹，保留 15 天
    "FOLDER|/data/backups|15|*|"

    # >>> 请在此处添加您的实际生产任务 <<<
    # 格式："MODE|PATH|DAYS|RULE|"
)

# ==============================================================================
# 【第三部分：初始化与基础函数】
# ==============================================================================

# 确保日志目录存在
mkdir -p "$SCRIPT_LOG_DIR"

# 定义本次运行的日志文件 (带时间戳，避免覆盖)
LOG_FILE="${SCRIPT_LOG_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

# 统计计数器
STAT_SCAN=0            # 扫描总数
STAT_DEL=0             # 成功删除数
STAT_FAIL=0            # 删除失败数
STAT_SKIP=0            # 正常跳过数 (未过期)
STAT_WARN_INTERCEPT=0  # 安全拦截数 (文件名过期但实际是新的)

# --- 日志输出函数 ---
log() { 
    local msg="[$(date '+%F %T')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}
log_warn() { 
    local msg="[$(date '+%F %T')] [WARN] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}
log_error() { 
    local msg="[$(date '+%F %T')] [ERROR] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

# --- 工具：计算 N 天前的日期 (返回 YYYYMMDD) ---
get_cutoff_date() {
    local days=$1
    # 兼容 Linux date 命令
    date -d "-${days} days" +"%Y%m%d" 2>/dev/null || date -v-${days}d +"%Y%m%d" 2>/dev/null
}

# --- 工具：获取文件/文件夹的最后修改时间 (返回 YYYYMMDD) ---
get_mtime_date() {
    local path="$1"
    # 提取修改时间并格式化
    stat -c '%y' "$path" 2>/dev/null | cut -d' ' -f1 | tr -d '-' || \
    stat -f '%Sm' -t '%Y%m%d' "$path" 2>/dev/null
}

# --- 工具：智能从文件名中提取日期 (核心逻辑) ---
# 支持格式：YYYY-MM-DD, YYYYMMDD
extract_date_from_name() {
    local name="$1"
    local date_str=""
    
    # 策略 A: 优先匹配带横杠格式 (2026-03-16)
    if [[ "$name" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
        date_str="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    
    # 策略 B: 匹配紧凑格式 (20260316)
    elif [[ "$name" =~ ([0-9]{4})([0-9]{2})([0-9]{2}) ]]; then
        local y=${BASH_REMATCH[1]}
        local m=${BASH_REMATCH[2]}
        local d=${BASH_REMATCH[3]}
        # 简单校验月份和日期合法性，防止误匹配长数字 ID
        if [[ $m -ge 1 && $m -le 12 && $d -ge 1 && $d -le 31 ]]; then
            date_str="${y}${m}${d}"
        fi
    fi
    
    echo "$date_str"
}

# ==============================================================================
# 【第四部分：核心处理逻辑】
# ==============================================================================

process_task() {
    local mode="$1"
    local target_dir="$2"
    local retain_days="$3"
    local rule="$4"
    
    # 1. 基础校验：目录是否存在
    if [[ ! -d "$target_dir" ]]; then
        log_error "[跳过] 目录不存在: $target_dir"
        return 1
    fi

    # 计算阈值日期和今天日期
    local cutoff_date=$(get_cutoff_date "$retain_days")
    local today_date=$(date +"%Y%m%d")

    # 校验日期计算是否成功
    if [[ -z "$cutoff_date" ]]; then
        log_error "[错误] 日期计算失败，请检查系统 date 命令。"
        return 1
    fi

    # --------------------------------------------------------------------------
    # 分支 1: FILE 模式 (全量文件清理)
    # 特点：递归遍历，基于 mtime (修改时间) 删除
    # --------------------------------------------------------------------------
    if [[ "$mode" == "FILE" ]]; then
        log ">>> [FILE] 开始处理: $target_dir (保留${retain_days}天, 后缀: ${rule:-'所有'})"
        
        # 构建 find 表达式
        # -type f: 仅文件
        # -mtime +N: 修改时间在 N 天前
        local find_expr="-type f -mtime +${retain_days}"
        
        # 如果指定了后缀，追加 -name 条件
        if [[ -n "$rule" ]]; then
            local name_args=""
            for ext in $rule; do
                name_args="$name_args -o -name '*${ext}'"
            done
            # 组合条件：\( -name '*.log' -o -name '*.txt' \)
            find_expr="$find_expr \( ${name_args#-o} \)"
        fi

        # 执行查找并循环删除
        # 注意：此处默认递归所有子目录
        while IFS= read -r -d '' file; do
            ((STAT_SCAN++))
            if rm -f "$file" 2>/dev/null; then
                log "已删除文件: $file"
                ((STAT_DEL++))
            else
                log_error "删除文件失败: $file"
                ((STAT_FAIL++))
            fi
        done < <(find "$target_dir" $find_expr -print0 2>/dev/null)

    # --------------------------------------------------------------------------
    # 分支 2: FOLDER 模式 (增量文件夹清理)
    # 特点：仅扫描一级目录，基于文件名日期 + mtime 双重校验
    # --------------------------------------------------------------------------
    elif [[ "$mode" == "FOLDER" ]]; then
        log ">>> [FOLDER] 开始处理: $target_dir (保留${retain_days}天, 前缀: $rule)"
        
        local use_wildcard=false
        local prefixes=()
        
        # 解析前缀规则
        if [[ "$rule" == "*" || -z "$rule" ]]; then
            use_wildcard=true
        else
            # 将逗号分隔的字符串转为数组
            IFS=',' read -ra prefixes <<< "$rule"
        fi

        # 遍历一级子目录
        for item_path in "$target_dir"/*; do
            # 必须是目录
            [[ -d "$item_path" ]] || continue
            
            local fname=$(basename "$item_path")
            
            # 步骤 1: 前缀匹配检查
            local is_match=false
            if [[ "$use_wildcard" == true ]]; then
                is_match=true
            else
                for prefix in "${prefixes[@]}"; do
                    prefix=$(echo "$prefix" | xargs) # 去除空格
                    if [[ "$fname" == ${prefix}* ]]; then
                        is_match=true
                        break
                    fi
                done
            fi
            
            # 前缀不匹配则跳过
            [[ "$is_match" == false ]] && continue

            # 步骤 2: 智能提取日期
            local item_date=$(extract_date_from_name "$fname")
            
            if [[ -z "$item_date" ]]; then
                log_warn "跳过 (未识别到日期): $fname"
                ((STAT_SKIP++))
                continue
            fi

            ((STAT_SCAN++))

            # 步骤 3: 初步判断 (基于文件名日期)
            # 【修复点】使用 -ge (数值大于等于) 替代 >= (字符串比较)，兼容旧版 Bash
            if [ "$item_date" -ge "$cutoff_date" ]; then
                # 日期较新，跳过
                ((STAT_SKIP++))
                continue
            fi

            # 步骤 4: 二次校验 (基于实际修改时间 mtime)
            # 场景防御：文件名写错了 (写成了很久以前)，但实际上是今天刚创建的
            local mtime_date=$(get_mtime_date "$item_path")
            
            # 【修复点】使用 = 进行字符串相等比较
            if [ "$mtime_date" = "$today_date" ]; then
                log_warn "🛡️ 拦截删除: $fname"
                log_warn "   -> 文件名日期: $item_date (看似过期)"
                log_warn "   -> 实际修改时间: $mtime_date (是今天)"
                log_warn "   -> 操作: 强制保留，防止误删"
                ((STAT_WARN_INTERCEPT++))
                ((STAT_SKIP++))
                continue
            fi

            # 步骤 5: 执行删除
            if rm -rf "$item_path" 2>/dev/null; then
                log "✅ 已删除文件夹: $item_path (文件名:$item_date, 修改时间:$mtime_date)"
                ((STAT_DEL++))
            else
                log_error "❌ 删除文件夹失败: $item_path"
                ((STAT_FAIL++))
            fi
        done
    else
        log_error "未知的任务模式: $mode"
    fi
}

# --- 系统自检：清理脚本自身的旧日志 ---
clean_self_logs() {
    local count=0
    # 查找并删除 SCRIPT_LOG_DIR 下超过保留天数的 run_*.log 文件
    while IFS= read -r -d '' f; do
        rm -f "$f" && ((count++))
    done < <(find "$SCRIPT_LOG_DIR" -type f -name "run_*.log" -mtime +${SCRIPT_LOG_RETAIN_DAYS} -print0 2>/dev/null)
    
    if [[ $count -gt 0 ]]; then
        log "[系统] 自动清理了 $count 个旧的运行日志"
    fi
}

# ==============================================================================
# 【第五部分：主执行流程】
# ==============================================================================

log "=========================================="
log "🚀 通用清理脚本启动 (PID: $$)"
log "📅 当前时间: $(date)"
log "📂 日志存档: $LOG_FILE"
log "📋 加载任务数量: ${#TASKS[@]}"
log "=========================================="

# 遍历执行所有任务
for task in "${TASKS[@]}"; do
    # 解析配置行 (以 | 分隔)
    IFS='|' read -r mode dir days rule extra <<< "$task"
    
    # 数据清洗：去除首尾空格
    mode=$(echo "$mode" | xargs)
    dir=$(echo "$dir" | xargs)
    days=$(echo "$days" | xargs)
    rule=$(echo "$rule" | xargs)
    
    # 基础校验
    if [[ -z "$mode" || -z "$dir" ]]; then
        log_error "⚠️ 无效的任务配置: $task"
        continue
    fi
    
    # 执行核心处理
    process_task "$mode" "$dir" "$days" "$rule"
    
    log "------------------------------------------"
done

# 执行自维护清理
clean_self_logs

# 输出最终统计报告
log "=========================================="
log "🏁 任务执行完毕"
log "📊 统计汇总:"
log "   扫描对象总数 : $STAT_SCAN"
log "   成功删除数   : $STAT_DEL"
log "   删除失败数   : $STAT_FAIL"
log "   正常跳过数   : $STAT_SKIP (未过期)"
log "   安全拦截数   : $STAT_WARN_INTERCEPT (文件名过期但修改时间为今天)"
log "=========================================="

# 如果有失败项，返回错误码 1 (便于监控告警)
if [[ $STAT_FAIL -gt 0 ]]; then
    log "⚠️ 警告：部分文件删除失败，请检查日志。"
    exit 1
else
    exit 0
fi
