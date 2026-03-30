#!/bin/bash

################################################################################
# 脚本名称: driver_manager.sh
# 版本: v1.1 (Final Release)
# 功能描述: 中间件驱动组件自动化升级与回滚工具
# 适用范围: 适用于多节点、多路径的驱动文件替换场景
# 核心逻辑: 
#   1. 替换模式：将旧文件移动（备份）至时间戳目录，并将新文件复制至原路径。
#   2. 回滚模式：支持按时间批次查看备份，自动清理当前新文件，并还原旧文件。
# 注意事项: 请确保执行用户具有目标目录的读写权限
################################################################################

# ================= 1. 全局配置区域 =================

# [新驱动源文件路径]
# 说明：请确保该文件存在，脚本会将此文件复制到所有目标目录
NEW_DRIVER="/path/to/new/DmJdbcDriver8.jar"

# [旧文件目标路径列表]
# 说明：在此处配置所有需要被替换的旧文件完整路径
# 逻辑：脚本会遍历此列表，将文件移动至备份区，并放入新文件
TARGET_FILES=(
    "/opt/app/server/runtime/3rd/DmJdbcDriver18.jar"
    "/opt/app/tools/bimodeltransfer/libs/DmJdbcDriver18.jar"
    "/opt/app/tools/deploy/data/runtime/3rd/DmJdbcDriver18.jar"
    "/opt/app/tools/deploy/metadata/runtime/3rd/DmJdbcDriver18.jar"
    "/opt/app/tools/deploy/idp/runtime/3rd/DmJdbcDriver18.jar"
    "/opt/app/tools/setup/libs/3rd/DmJdbcDriver18.jar"
    "/opt/app/tools/emc/runtime/3rd/DmJdbcDriver18.jar"
    "/opt/app/tools/update/runtime/3rd/DmJdbcDriver18.jar"
    "/opt/app/tools/lic-tool/runtime/3rd/DmJdbcDriver18.jar"
    "/opt/app/tools/perf/database-monitor/runtime/3rd/DmJdbcDriver18.jar"
    "/opt/app/tools/backup/tools_bak/emc/runtime/3rd/DmJdbcDriver18.jar"
    "/opt/app/tools/backup/tools_bak/update/runtime/3rd/DmJdbcDriver18.jar"
)

# [自动获取脚本所在路径]
# 逻辑：确保备份目录始终跟随脚本，不依赖硬编码路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# [备份根目录]
# 说明：所有历史备份将存储在此目录下的子文件夹中
BACKUP_BASE_DIR="${SCRIPT_DIR}/backup"

# [操作日志路径]
LOG_FILE="${BACKUP_BASE_DIR}/operation.log"

# ================= 2. 通用工具函数 =================

# 日志记录函数：同时输出到标准输出和日志文件
log_message() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

# 前置检查：验证新驱动文件是否存在
check_new_driver() {
    if [ ! -f "$NEW_DRIVER" ]; then
        log_message "错误: 找不到新的驱动包 $NEW_DRIVER"
        echo "错误: 找不到新的驱动包 $NEW_DRIVER"
        exit 1
    fi
}

# ================= 3. 核心业务：执行替换 =================

do_replace() {
    # 1. 初始化环境与检查
    mkdir -p "$BACKUP_BASE_DIR"
    check_new_driver

    # 获取新文件的文件名（例如：DmJdbcDriver8.jar）
    NEW_FILENAME=$(basename "$NEW_DRIVER")

    # 生成基于时间戳的唯一备份目录名
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    CURRENT_BACKUP_DIR="${BACKUP_BASE_DIR}/${TIMESTAMP}"
    mkdir -p "$CURRENT_BACKUP_DIR"

    log_message "----------------------------------------"
    log_message "开始执行替换任务，备份目录: $CURRENT_BACKUP_DIR"

    # 2. 备份旧文件（使用 mv 命令实现安全移动）
    log_message "步骤 1: 正在移动旧文件到备份区..."
    local has_backup=false

    for old_file in "${TARGET_FILES[@]}"; do
        if [ -f "$old_file" ]; then
            # 获取旧文件所在的目录路径
            target_dir=$(dirname "$old_file")
            
            # 在备份目录中复刻相同的目录结构
            backup_target_dir="${CURRENT_BACKUP_DIR}${target_dir}"
            mkdir -p "$backup_target_dir"
            
            # 使用 mv 命令将旧文件“剪切”到备份目录
            # 优势：相比 cp+rm，mv 原子性更好，且避免了 rm 误删风险
            mv "$old_file" "$backup_target_dir/"
            
            if [ $? -eq 0 ]; then
                log_message "已移动(备份): $old_file"
                has_backup=true
            else
                log_message "错误: 无法移动 $old_file"
            fi
        else
            log_message "警告: 旧文件不存在 (跳过): $old_file"
        fi
    done

    # 如果没有备份到任何文件，说明目标路径均无效，中止操作
    if [ "$has_backup" = false ]; then
        log_message "错误: 没有找到任何需要替换的旧文件，操作中止。"
        rm -rf "$CURRENT_BACKUP_DIR"
        exit 1
    fi

    # 3. 部署新文件
    log_message "步骤 2: 正在部署新驱动 ($NEW_FILENAME)..."
    local success_count=0
    local fail_count=0
    
    for old_file in "${TARGET_FILES[@]}"; do
        # 获取目标目录路径
        target_dir=$(dirname "$old_file")
        
        # 拼接新文件的完整目标路径
        TARGET_PATH="${target_dir}/${NEW_FILENAME}"
        
        # 复制新文件到目标位置
        cp -f "$NEW_DRIVER" "$TARGET_PATH"
        
        if [ $? -eq 0 ]; then
            log_message "成功: $TARGET_PATH 已部署"
            ((success_count++))
        else
            log_message "失败: $TARGET_PATH 部署失败"
            ((fail_count++))
        fi
    done

    log_message "----------------------------------------"
    log_message "任务结束。成功: $success_count, 失败: $fail_count"
    log_message "备份位置: $CURRENT_BACKUP_DIR"
    echo "✅ 替换完成。备份ID: $TIMESTAMP"
}

# ================= 4. 核心业务：执行回滚 =================

do_rollback() {
    # 1. 检查备份目录是否存在
    if [ ! -d "$BACKUP_BASE_DIR" ]; then
        echo "❌ 备份目录不存在，无法回滚。"
        exit 1
    fi

    # 2. 获取所有备份批次并按时间倒序排列
    # 逻辑：ls -dt 确保最新的备份排在最前面
    mapfile -t backups < <(ls -dt "$BACKUP_BASE_DIR"/*/ 2>/dev/null | xargs -I {} basename {})
    
    # 过滤：仅保留符合时间戳格式（YYYYMMDD_HHMMSS）的目录
    valid_backups=()
    for dir in "${backups[@]}"; do
        if [[ "$dir" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
            valid_backups+=("$dir")
        fi
    done

    if [ ${#valid_backups[@]} -eq 0 ]; then
        echo "❌ 没有找到任何有效的备份批次。"
        exit 1
    fi

    # 3. 展示回滚菜单
    echo "========================================"
    echo "   可选的备份批次 (按时间倒序)"
    echo "========================================"
    echo "序号 | 批次时间戳 (ID)      | 状态"
    echo "-----|----------------------|------"
    
    for i in "${!valid_backups[@]}"; do
        # 简单校验备份完整性（检查是否包含 opt 目录）
        local status="正常"
        if [ ! -d "${BACKUP_BASE_DIR}/${valid_backups[$i]}/opt" ]; then
            status="异常(缺文件)"
        fi
        printf "  %-2d | %s | %s\n" "$((i+1))" "${valid_backups[$i]}" "$status"
    done
    echo "-----|----------------------|------"
    echo "   0 | 退出程序"
    echo "========================================"
    
    # 4. 处理用户输入
    while true; do
        read -p "请输入要回滚的批次序号: " choice
        
        if [ "$choice" == "0" ]; then
            echo "退出回滚。"
            exit 0
        fi

        # 验证输入是否为有效数字
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#valid_backups[@]}" ]; then
            echo "❌ 无效的输入，请输入 1 到 ${#valid_backups[@]} 之间的数字。"
            continue
        fi

        # 5. 执行回滚操作
        local selected_backup="${valid_backups[$((choice-1))]}"
        local TARGET_BACKUP="${BACKUP_BASE_DIR}/${selected_backup}"

        echo "ℹ️ 准备回滚到批次: $selected_backup"
        read -p "⚠️ 确认要覆盖当前文件吗? (y/n): " confirm
        
        if [ "$confirm" == "y" ] || [ "$confirm" == "Y" ]; then
            log_message "----------------------------------------"
            log_message "开始回滚操作，使用批次: $selected_backup"
            
            if [ -d "${TARGET_BACKUP}/opt" ]; then
                # --- 新增步骤 A: 清理新文件 ---
                # 获取新文件的文件名 (例如 DmJdbcDriver8.jar)
                NEW_FILENAME=$(basename "$NEW_DRIVER")
                log_message "正在清理残留的新文件 ($NEW_FILENAME)..."
                
                for old_file in "${TARGET_FILES[@]}"; do
                    target_dir=$(dirname "$old_file")
                    new_file_path="${target_dir}/${NEW_FILENAME}"
                    
                    # 如果新文件存在，则删除它
                    if [ -f "$new_file_path" ]; then
                        rm -f "$new_file_path"
                        log_message "已清理: $new_file_path"
                    fi
                done

                # --- 原有步骤 B: 还原旧文件 ---
                log_message "正在还原旧文件..."
                cp -rf "${TARGET_BACKUP}/opt" "/opt/"
                
                if [ $? -eq 0 ]; then
                    log_message "回滚成功: 文件已恢复"
                    echo "✅ 回滚操作成功完成。"
                    exit 0
                else
                    log_message "回滚失败: 复制文件时出错"
                    echo "❌ 回滚操作失败，请检查权限。"
                    exit 1
                fi
            else
                echo "❌ 备份数据结构损坏，无法回滚。"
                exit 1
            fi
        else
            echo "已取消回滚。"
            exit 0
        fi
    done
}

# ================= 5. 主菜单入口 =================

show_menu() {
    echo "========================================"
    echo "   中间件驱动组件管理工具"
    echo "========================================"
    echo "1. 执行替换 (移动旧文件并部署新驱动)"
    echo "2. 执行回滚 (按批次恢复旧版本)"
    echo "3. 退出"
    echo "========================================"
    read -p "请选择操作 [1-3]: " action

    case $action in
        1)
            do_replace
            ;;
        2)
            do_rollback
            ;;
        3)
            echo "退出程序。"
            exit 0
            ;;
        *)
            echo "❌ 无效输入，请重试。"
            exit 1
            ;;
    esac
}

# 启动程序
show_menu
