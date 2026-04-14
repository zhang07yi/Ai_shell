#!/bin/bash

################################################################################
# 脚本名称: driver_manager.sh
# 版本: v1.2
# 功能描述: 中间件驱动组件自动化升级与回滚工具
# 使用场景: 多节点、多路径的驱动文件替换与恢复
################################################################################

# ================= 1. 全局配置区域 =================

# 新驱动源文件路径（需要替换成实际路径）
NEW_DRIVER="/path/to/new/DmJdbcDriver8.jar"

# 旧文件目标路径列表（所有需要替换的文件路径）
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

# 自动获取脚本所在路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 备份根目录（所有历史备份会存放在这里）
BACKUP_BASE_DIR="${SCRIPT_DIR}/backup"

# 操作日志路径
LOG_FILE="${BACKUP_BASE_DIR}/operation.log"

# ================= 2. 通用工具函数 =================

# 日志记录函数：输出到终端并写入日志文件
log_message() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

# 检查新驱动文件是否存在
check_new_driver() {
    if [ ! -f "$NEW_DRIVER" ]; then
        log_message "错误: 找不到新的驱动包 $NEW_DRIVER"
        exit 1
    fi
}

# ================= 3. 替换逻辑 =================

do_replace() {
    mkdir -p "$BACKUP_BASE_DIR"
    check_new_driver

    NEW_FILENAME=$(basename "$NEW_DRIVER")
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    CURRENT_BACKUP_DIR="${BACKUP_BASE_DIR}/${TIMESTAMP}"
    mkdir -p "$CURRENT_BACKUP_DIR"

    log_message "开始替换，备份目录: $CURRENT_BACKUP_DIR"

    local has_backup=false
    # 遍历所有目标文件，逐一备份
    for old_file in "${TARGET_FILES[@]}"; do
        if [ -f "$old_file" ]; then
            target_dir=$(dirname "$old_file")
            backup_target_dir="${CURRENT_BACKUP_DIR}${target_dir}"
            mkdir -p "$backup_target_dir"
            mv "$old_file" "$backup_target_dir/"
            if [ $? -eq 0 ]; then
                log_message "已备份: $old_file"
                has_backup=true
            else
                log_message "错误: 无法备份 $old_file"
            fi
        else
            log_message "警告: 未找到旧文件 $old_file"
        fi
    done

    if [ "$has_backup" = false ]; then
        log_message "错误: 没有找到任何旧文件，操作中止。"
        rm -rf "$CURRENT_BACKUP_DIR"
        exit 1
    fi

    local success_count=0 fail_count=0
    # 部署新文件
    for old_file in "${TARGET_FILES[@]}"; do
        target_dir=$(dirname "$old_file")
        TARGET_PATH="${target_dir}/${NEW_FILENAME}"
        cp -f "$NEW_DRIVER" "$TARGET_PATH"
        if [ $? -eq 0 ]; then
            log_message "成功部署: $TARGET_PATH"
            ((success_count++))
        else
            log_message "失败部署: $TARGET_PATH"
            ((fail_count++))
        fi
    done

    log_message "替换完成。成功: $success_count, 失败: $fail_count"
    echo "✅ 替换完成。备份ID: $TIMESTAMP"
}

# ================= 4. 回滚逻辑 =================

do_rollback() {
    if [ ! -d "$BACKUP_BASE_DIR" ]; then
        echo "❌ 没有备份目录，无法回滚。"
        exit 1
    fi

    # 获取所有备份批次
    mapfile -t backups < <(ls -dt "$BACKUP_BASE_DIR"/*/ 2>/dev/null | xargs -I {} basename {})
    valid_backups=()
    for dir in "${backups[@]}"; do
        [[ "$dir" =~ ^[0-9]{8}_[0-9]{6}$ ]] && valid_backups+=("$dir")
    done

    if [ ${#valid_backups[@]} -eq 0 ]; then
        echo "❌ 没有有效备份。"
        exit 1
    fi

    echo "可选备份批次:"
    for i in "${!valid_backups[@]}"; do
        printf "%2d | %s\n" "$((i+1))" "${valid_backups[$i]}"
    done
    echo " 0 | 退出"

    read -p "请输入要回滚的序号: " choice
    [[ "$choice" == "0" ]] && exit 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#valid_backups[@]}" ]; then
        echo "❌ 输入无效"
        exit 1
    fi

    selected_backup="${valid_backups[$((choice-1))]}"
    TARGET_BACKUP="${BACKUP_BASE_DIR}/${selected_backup}"

    read -p "⚠️ 确认回滚到 $selected_backup ? (y/n): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

    NEW_FILENAME=$(basename "$NEW_DRIVER")
    log_message "开始回滚，批次: $selected_backup"

    # 删除新文件
    for old_file in "${TARGET_FILES[@]}"; do
        target_dir=$(dirname "$old_file")
        new_file_path="${target_dir}/${NEW_FILENAME}"
        [ -f "$new_file_path" ] && rm -f "$new_file_path" && log_message "已删除新文件: $new_file_path"
    done

    # 恢复旧文件
    local restore_success=0 restore_fail=0
    for old_file in "${TARGET_FILES[@]}"; do
        backup_file="${TARGET_BACKUP}${old_file}"
        if [ -f "$backup_file" ]; then
            cp -f "$backup_file" "$old_file"
            if [ $? -eq 0 ]; then
                log_message "已恢复: $old_file"
                ((restore_success++))
            else
                log_message "错误: 恢复失败 $old_file"
                ((restore_fail++))
            fi
        else
            log_message "警告: 备份缺失 $backup_file"
        fi
    done

    log_message "回滚完成。成功: $restore_success, 失败: $restore_fail"
    echo "✅ 回滚完成。"
}

# ================= 5. 主菜单 =================

show_menu() {
    echo "========================================"
    echo "   中间件驱动组件管理工具"
    echo "========================================"
    echo "1. 执行替换"
    echo "2. 执行回滚"
    echo "3. 退出"
    echo "========================================"
    read -p "请选择操作 [1-3]: " action
    case $action in
        1) do_replace ;;
        2) do_rollback ;;
        3) exit 0 ;;
        *) echo "❌ 无效输入" ;;
    esac
}

# 启动程序
show_menu
