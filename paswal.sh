#CKS节点 - 最终稳定版
# 使用节点ID配置，确保功能正常，Web界面自动显示完整名称
# ==========================================

# 设置PATH确保命令可用
PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# -------- 基本设置 --------
CONFIG_FILE="/etc/config/passwall"
URL="https://www.google.com/generate_204"
TIMEOUT=15
PORT_WAIT_MAX=30
TMP_GOOD="/tmp/passwall_good_nodes.txt"
TMP_BAD="/tmp/passwall_bad_nodes.txt"
PROXY_PORT="1081"
PROXY_TYPE="socks5"

# 修复：扩展SOCKS协议识别列表
SOCKS_PROTOCOLS="socks socks5 Socks Socks5 SOCKS SOCKS5"

BACKUP_FIELD="autoswitch_backup_node"
CURRENT_NODE_FIELD="node"

# 添加计数变量
START_TIME=$(date +%s)
CURRENT_TEST=0
TOTAL_TESTS=0

echo "============================"
echo "🕓 $(date '+%F %T') - 开始测试（最终稳定版）"
echo "============================"

# 清空临时文件
> "$TMP_GOOD"
> "$TMP_BAD"

# -------- 获取正确的SOCKS配置段 --------
echo "📋 检测SOCKS配置段..."
SOCKS_SECTION=""

# 方法1：尝试 @socks[0]
if uci get passwall.@socks[0].$CURRENT_NODE_FIELD >/dev/null 2>&1; then
    SOCKS_SECTION="@socks[0]"
    echo "✅ 找到配置段: $SOCKS_SECTION"
else
    # 方法2：查找其他可能的配置段
    POSSIBLE_SECTIONS=$(uci show passwall 2>/dev/null | grep -E "=socks|S3fK839r" | cut -d'.' -f2 | cut -d'=' -f1)
    for section in $POSSIBLE_SECTIONS; do
        if uci get passwall.$section.$CURRENT_NODE_FIELD >/dev/null 2>&1; then
            SOCKS_SECTION="$section"
            echo "✅ 找到配置段: $SOCKS_SECTION"
            break
        fi
    done
fi

if [ -z "$SOCKS_SECTION" ]; then
    echo "❌ 未找到有效的SOCKS配置段，退出"
    exit 1
fi

# -------- 函数：获取节点显示名称（用于日志输出） --------
get_node_display_name() {
    local NODE_ID="$1"
    lua -e "
        package.path = package.path .. ';/usr/lib/lua/?.lua'
        local api = require 'luci.passwall.api'
        local uci = api.uci
        local node_data = uci:get_all('passwall', '$NODE_ID')
        if node_data then
            local full_name = api.get_full_node_remarks(node_data)
            print(full_name)
        else
            print('$NODE_ID')
        end
    " 2>/dev/null
}

# -------- 函数：检查节点是否有效 --------
is_valid_node() {
    local NODE_ID="$1"
    
    # 检查节点是否存在
    if ! uci get passwall.$NODE_ID >/dev/null 2>&1; then
        return 1
    fi
    
    # 检查是否有remarks字段
    local REMARKS=$(uci get passwall.$NODE_ID.remarks 2>/dev/null)
    if [ -z "$REMARKS" ]; then
        return 1
    fi
    # 检查是否有address字段
    local ADDRESS=$(uci get passwall.$NODE_ID.address 2>/dev/null)
    if [ -z "$ADDRESS" ]; then
        return 1
    fi
    
    return 0
}

# -------- 获取所有有效节点 --------
echo "📋 获取节点列表并过滤无效节点..."
ALL_NODES=$(uci show passwall 2>/dev/null | grep "=nodes" | cut -d'.' -f2 | cut -d'=' -f1)
VALID_NODES=""
INVALID_COUNT=0

if [ -z "$ALL_NODES" ]; then
    echo "⚠️ 未检测到任何节点，退出"
    exit 1
fi

echo "原始节点数量: $(echo $ALL_NODES | wc -w) 个"

# 过滤有效节点
for ID in $ALL_NODES; do
    if is_valid_node "$ID"; then
        VALID_NODES="$VALID_NODES $ID"
    else
        INVALID_COUNT=$((INVALID_COUNT + 1))
        NODE_DISPLAY=$(get_node_display_name "$ID")
        echo "  ⚠️ 跳过无效节点 [$ID]: $NODE_DISPLAY"
    fi
done

VALID_NODES=$(echo $VALID_NODES | sed 's/^ *//')  # 去除开头空格
VALID_COUNT=$(echo $VALID_NODES | wc -w)

if [ $VALID_COUNT -eq 0 ]; then
    echo "❌ 无有效节点，退出"
    exit 1
fi

echo "✅ 有效节点数量: $VALID_COUNT 个"
echo "❌ 无效节点数量: $INVALID_COUNT 个"

# -------- 逐个测试节点 --------
TOTAL_TESTS=$VALID_COUNT
CURRENT_TEST=0

for ID in $VALID_NODES; do
    CURRENT_TEST=$((CURRENT_TEST + 1))
    NODE_DISPLAY=$(get_node_display_name "$ID")
    NODE_TYPE=$(uci get passwall.$ID.type 2>/dev/null)
    NODE_PROTOCOL=$(uci get passwall.$ID.protocol 2>/dev/null)
    [ -z "$NODE_TYPE" ] && NODE_TYPE="unknown"
    [ -z "$NODE_PROTOCOL" ] && NODE_PROTOCOL="unknown"

    echo "➡️ 测试节点 [$CURRENT_TEST/$TOTAL_TESTS]: $NODE_DISPLAY (协议: $NODE_TYPE/$NODE_PROTOCOL)"

    # 第一层过滤：跳过SOCKS节点
    case " $SOCKS_PROTOCOLS " in
        *" $NODE_TYPE "*)
            echo "  📌 是SOCKS节点，跳过测试"
            continue
            ;;
    esac
    
    echo "  设置节点$ID为当前节点..."
    
    # 根据配置段类型使用不同的uci语法
    if [ "$SOCKS_SECTION" = "@socks[0]" ]; then
        uci set passwall.@socks[0].$CURRENT_NODE_FIELD="$ID"
    else
        uci set passwall.$SOCKS_SECTION.$CURRENT_NODE_FIELD="$ID"
    fi
    uci commit passwall

    # 重载PassWall
    echo "  重载PassWall..."
    if ! /etc/init.d/passwall reload >/dev/null 2>&1; then
        echo "⚠️ 重载失败，标记为无效"
        echo "$ID" >> "$TMP_BAD"
        continue
    fi

    # 等待端口就绪
    echo "  等待端口$PROXY_PORT就绪（最长$PORT_WAIT_MAX秒）..."
    WAIT=0
    PORT_READY=0
    while [ $WAIT -lt $PORT_WAIT_MAX ]; do
    if netstat -tuln 2>/dev/null | grep -q ":$PROXY_PORT "; then
        echo "  ✅ 端口$PROXY_PORT已就绪"
        PORT_READY=1
        break
    fi
    sleep 1
    WAIT=$((WAIT+1))
    [ $((WAIT % 5)) -eq 0 ] && echo "  等待中... ($WAIT/$PORT_WAIT_MAX秒)"
    done

if [ $PORT_READY -eq 0 ]; then
    echo "⚠️ 端口未就绪（超时），可能代理未启动"
    echo "$ID" >> "$TMP_BAD"
    continue
fi     

    # 测试代理连通性
    echo "  测试代理连通性..."
    curl -I -s -m $TIMEOUT --$PROXY_TYPE 127.0.0.1:$PROXY_PORT "$URL" >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "✅ 节点[$NODE_DISPLAY]测试通过"
        echo "$ID" >> "$TMP_GOOD"
    else
        echo "❌ 节点[$NODE_DISPLAY]测试失败"
        echo "$ID" >> "$TMP_BAD"
    fi
    echo "--------------------------------------------"
done

# -------- 汇总有效节点 --------
if [ ! -s "$TMP_GOOD" ]; then
    echo "⚠️ 无可用非SOCKS节点，退出"
    rm -f "$TMP_GOOD" "$TMP_BAD"
    exit 1
fi

# 直接使用测试结果（测试阶段已确保都是非SOCKS节点）
echo "🔍 确认可用节点列表..."
GOOD_NODES=$(cat "$TMP_GOOD")
GOOD_NODES_COUNT=$(echo "$GOOD_NODES" | wc -w)

echo "✅ 最终可用非SOCKS节点: $GOOD_NODES_COUNT 个"

# -------- 更新SOCKS配置（使用节点ID） --------
echo "🔄 更新SOCKS配置（使用节点ID）..."

# 清空备用节点列表
echo "  清空备用节点列表..."
if [ "$SOCKS_SECTION" = "@socks[0]" ]; then
    uci delete passwall.@socks[0].$BACKUP_FIELD 2>/dev/null
else
    uci delete passwall.$SOCKS_SECTION.$BACKUP_FIELD 2>/dev/null
fi
uci commit passwall

# 添加非SOCKS节点到备用列表（使用节点ID）
echo "  添加非SOCKS节点到备用列表..."
# 设置当前节点（使用节点ID）
FIRST_GOOD_NODE=$(echo "$GOOD_NODES" | head -1)
FIRST_NODE_DISPLAY=$(get_node_display_name "$FIRST_GOOD_NODE")
for ID in $GOOD_NODES; do
    # 跳过主节点
    if [ "$ID" = "$FIRST_GOOD_NODE" ]; then
        continue
    fi
    NODE_DISPLAY=$(get_node_display_name "$ID")
    
    if [ "$SOCKS_SECTION" = "@socks[0]" ]; then
        uci add_list passwall.@socks[0].$BACKUP_FIELD="$ID"
    else
        uci add_list passwall.$SOCKS_SECTION.$BACKUP_FIELD="$ID"
    fi
    echo "  ✅ 添加节点到Socks自动切换: $NODE_DISPLAY"
done
if [ "$SOCKS_SECTION" = "@socks[0]" ]; then
    uci set passwall.@socks[0].$CURRENT_NODE_FIELD="$FIRST_GOOD_NODE"
else
    uci set passwall.$SOCKS_SECTION.$CURRENT_NODE_FIELD="$FIRST_GOOD_NODE"
fi
echo "  设置当前节点为: $FIRST_NODE_DISPLAY (ID: $FIRST_GOOD_NODE)"

# -------- 提交并重启 --------
uci commit passwall
echo "🔄 重启PassWall..."
/etc/init.d/passwall restart >/dev/null 2>&1

# -------- 验证配置 --------
echo "🔍 验证最终配置..."
if [ "$SOCKS_SECTION" = "@socks[0]" ]; then
    FINAL_BACKUP_NODES=$(uci get passwall.@socks[0].$BACKUP_FIELD 2>/dev/null)
    FINAL_CURRENT_NODE=$(uci get passwall.@socks[0].$CURRENT_NODE_FIELD 2>/dev/null)
else
    FINAL_BACKUP_NODES=$(uci get passwall.$SOCKS_SECTION.$BACKUP_FIELD 2>/dev/null)
    FINAL_CURRENT_NODE=$(uci get passwall.$SOCKS_SECTION.$CURRENT_NODE_FIELD 2>/dev/null)
fi

echo "当前节点ID: $FINAL_CURRENT_NODE"
echo "当前节点显示: $(get_node_display_name "$FINAL_CURRENT_NODE")"
echo "备用节点ID列表: $FINAL_BACKUP_NODES"

# 检查是否有SOCKS节点混入
if [ -n "$FINAL_BACKUP_NODES" ]; then
    HAS_SOCKS=0
    for NODE_ID in $FINAL_BACKUP_NODES; do
        NODE_TYPE=$(uci get passwall.$NODE_ID.type 2>/dev/null)
        case " $SOCKS_PROTOCOLS " in
            *" $NODE_TYPE "*)
                NODE_DISPLAY=$(get_node_display_name "$NODE_ID")
                echo "⚠️ 警告: 备用节点中仍存在SOCKS节点: $NODE_DISPLAY"
                HAS_SOCKS=1
                ;;
        esac
    done
    if [ $HAS_SOCKS -eq 0 ]; then
        echo "✅ 备用节点列表纯净，无SOCKS节点"
    fi
else
    echo "⚠️ 备用节点列表为空"
fi

# -------- 清理临时文件 --------
rm -f "$TMP_GOOD" "$TMP_BAD"

# -------- 计算总用时 --------
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
MINUTES=$((TOTAL_TIME / 60))
SECONDS=$((TOTAL_TIME % 60))

echo "============================"
echo "✅ 操作完成"
echo "📊 统计信息:"
echo "   - 原始节点总数: $(echo $ALL_NODES | wc -w) 个"
echo "   - 有效节点数量: $VALID_COUNT 个"
echo "   - 无效节点数量: $INVALID_COUNT 个"
echo "   - 可用非SOCKS节点: $GOOD_NODES_COUNT 个"
echo "   - 已添加到Socks自动切换"
echo "⏱️ 用时统计:"
echo "   - 开始时间: $(date -d "@$START_TIME" '+%F %T')"
echo "   - 结束时间: $(date -d "@$END_TIME" '+%F %T')"
echo "   - 总用时: ${MINUTES}分${SECONDS}秒"
echo "============================"