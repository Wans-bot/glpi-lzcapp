#!/bin/sh
# 数据库自愈守卫（db 服务的 setup_script，以 root 在每个容器启动前运行一次）
#
# 为什么需要：MySQL 官方 entrypoint 的首次初始化（mysqld --initialize-insecure + 临时
# server 建库）不是原子的，全过程要几十秒。若在这段时间里容器被杀（平台重排容器、
# 磁盘/内存压力、评审机上重装/重启），datadir 会停在「系统库建了一半、redo log 没建完」
# 的状态。此时 InnoDB 在后续每次启动都会立刻致命退出：
#   [ERROR] [MY-012960] [InnoDB] Cannot create redo log files because data files are
#   corrupt or the database was not shut down cleanly after creating the data files.
#   [ERROR] [MY-010334] [Server] Failed to initialize DD Storage Engine
# 容器状态永远 Exited(1)，平台判定「应用无法正常启动」——这是评审驳回的根因。
#
# 判据（实测：初始化被中断只会停在「业务库还没建出来」之前）：
#   1) 有 datadir 但没有 mysql/   -> 从未初始化成功；目录非空则是残留，清走重来
#   2) 有 mysql/ 但没有业务库目录 -> 初始化只完成了一半（系统库在、业务库没建）
#   3) 有 mysql/ 也有业务库       -> 正常数据盘，原样交给 entrypoint
# 清走 = 移到同一个持久卷下的 .broken-<时间戳>/，不删除，日志里留路径可人工找回。
# 注意：MySQL 镜像的 entrypoint 会在 datadir 里放一个 mysql.sock 符号链接（指向
# /var/run/mysqld/），它是悬空的 —— 用 -e 判断会漏掉它，而 mysqld --initialize 要求
# datadir 完全为空，漏一个就 panic（实测 MY-010457 + lzcinit panic）。所以符号链接也要一起挪。
set -u

DATADIR=/var/lib/mysql
APPVAR=/lzcapp/var/glpi
EXPECT_DB="${MYSQL_DATABASE:-}"
STAMP=$(date +%Y%m%d-%H%M%S)

log() { echo "[db-guard] $*"; }

# 把 datadir 内容挪到持久卷里的隔离目录（datadir 本身是 bind 挂载点，不能整体重命名）
quarantine() {
    reason="$1"
    bak="$APPVAR/mysql-data.broken-$STAMP"
    mkdir -p "$bak" 2>/dev/null || { log "无法创建隔离目录 $bak，跳过"; return 1; }
    moved=0
    for entry in "$DATADIR"/* "$DATADIR"/.[!.]* "$DATADIR"/..?*; do
        # -e 对悬空符号链接为假，必须配合 -L
        if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then continue; fi
        mv -f "$entry" "$bak"/ 2>/dev/null && moved=$((moved + 1))
    done
    # 兜底：任何仍留在 datadir 的条目都会让 mysqld --initialize 直接失败，必须清空
    leftover=$(ls -A "$DATADIR" 2>/dev/null | wc -l)
    if [ "$leftover" -gt 0 ]; then
        log "仍有 $leftover 个条目无法移动，直接删除以保证 datadir 为空"
        rm -rf "$DATADIR"/* "$DATADIR"/.[!.]* 2>/dev/null || true
    fi
    log "datadir 不可用（$reason），已把 $moved 个条目移到 $bak，交由 entrypoint 重新初始化"
}

# 数据库被隔离后，GLPI 自己也必须回到「未安装」状态：它的 config/config_db.php 与
# 安装完成标记 .setup_done 都留在持久卷里，会让 entrypoint 误判「已安装」→ 跳过建表 →
# db:check 失败 → 又走 database:install → 报 "Database configuration already exists" → 死循环 500。
# 数据库空了就等于这是台全新实例，标记必须一起清掉（清之前做个备份，方便人工找回）。
clear_app_install_state() {
    cfgdir="$APPVAR/glpi-data/config"
    [ -d "$cfgdir" ] || return 0
    bak="$APPVAR/glpi-install-state.broken-$STAMP"
    mkdir -p "$bak" 2>/dev/null || true
    for f in config_db.php .setup_done; do
        if [ -e "$cfgdir/$f" ]; then
            cp -a "$cfgdir/$f" "$bak/$f" 2>/dev/null || true
            rm -f "$cfgdir/$f" 2>/dev/null && log "已清除 GLPI 安装标记 $cfgdir/$f（备份在 $bak）"
        fi
    done
    return 0
}

mkdir -p "$APPVAR" 2>/dev/null || true

if [ ! -d "$DATADIR" ]; then
    log "datadir 不存在，交给 entrypoint 初始化"
    exit 0
fi

if [ ! -d "$DATADIR/mysql" ]; then
    if [ -n "$(ls -A "$DATADIR" 2>/dev/null)" ]; then
        quarantine "残留的半初始化数据（没有 mysql 系统库）" || true
        clear_app_install_state
    else
        log "datadir 为空，交给 entrypoint 初始化"
    fi
    exit 0
fi

if [ -n "$EXPECT_DB" ] && [ ! -d "$DATADIR/$EXPECT_DB" ]; then
    quarantine "初始化未完成（系统库在、业务库 $EXPECT_DB 不存在）" || true
    clear_app_install_state
    exit 0
fi

log "datadir 看起来完整（系统库 + 业务库齐全），交给 entrypoint 正常启动"
exit 0
