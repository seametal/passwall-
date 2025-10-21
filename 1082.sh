#KS1082性能优化脚本（修复版）- 使用节点ID配置
MAIN_SOCKS="@socks[0]"    # 源服务器 (1081)
NEW_SOCKS="@socks[1]"     # 新主服务器 (1082)
NEW_PORT="1082"

# 多个测试URL
TEST_URLS="https://www.google.com/generate_204 https://www.google.com/generate_204 https://www.google.com/generate_204"

echo "🚀 开始优化SOCKS1082配置..."

# -------- 函数：获取节点完整显示名称 --------
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
    
    # 检查是否有protocol字段
    local PROTOCOL=$(uci get passwall.$NODE_ID.protocol 2>/dev/null)
    if [ -z "$PROTOCOL" ]; then
        return 1
    fi
    
    return 0
}

# 1. 从1081获取节点列表和备注
echo "📋 从SOCKS1081获取节点配置..."
CURRENT_NODE=$(uci get passwall.$MAIN_SOCKS.node)
BACKUP_NODES=$(uci get passwall.$MAIN_SOCKS.autoswitch_backup_node)

# 合并所有节点并去重
ALL_NODES=$(echo "$CURRENT_NODE $BACKUP_NODES" | tr ' ' '\n' | sort -u | tr '\n' ' ')

# 过滤有效节点
VALID_NODES=""
INVALID_COUNT=0

for NODE in $ALL_NODES; do
    if is_valid_node "$NODE"; then
        VALID_NODES="$VALID_NODES $NODE"
    else
        INVALID_COUNT=$((INVALID_COUNT + 1))
        NODE_DISPLAY=$(get_node_display_name "$NODE")
        echo "  ⚠️ 跳过无效节点 [$NODE]: $NODE_DISPLAY"
    fi
done

VALID_NODES=$(echo $VALID_NODES | sed 's/^ *//')  # 去除开头空格
NODE_COUNT=$(echo "$VALID_NODES" | wc -w)

if [ $NODE_COUNT -eq 0 ]; then
    echo "❌ 无有效节点，退出"
    exit 1
fi

echo "获取到有效节点: $NODE_COUNT 个"
echo "跳过无效节点: $INVALID_COUNT 个"

# 2. 启用1082服务器
echo "🔧 启用SOCKS1082测试环境..."
uci set passwall.$NEW_SOCKS.enabled="1"
uci commit passwall
/etc/init.d/passwall reload
sleep 3

# 3. 测试每个节点的响应时间
echo "⏱️ 开始性能测试..."
declare -A node_speeds
declare -A node_display_names
declare -A node_success_rates

for NODE in $VALID_NODES; do
    # 获取节点完整显示名称
    NODE_DISPLAY=$(get_node_display_name "$NODE")
    NODE_TYPE=$(uci get passwall.$NODE.type 2>/dev/null)
    NODE_PROTOCOL=$(uci get passwall.$NODE.protocol 2>/dev/null)
    [ -z "$NODE_TYPE" ] && NODE_TYPE="unknown"
    [ -z "$NODE_PROTOCOL" ] && NODE_PROTOCOL="unknown"
    
    node_display_names[$NODE]="$NODE_DISPLAY"
    
    echo "测试节点: $NODE_DISPLAY (协议: $NODE_TYPE/$NODE_PROTOCOL)"
    
    # 设置测试节点
    uci set passwall.$NEW_SOCKS.node="$NODE"
    uci commit passwall
    /etc/init.d/passwall reload
    sleep 2
    
    # 多URL测试
    TOTAL_TIME=0
    SUCCESS_COUNT=0
    URL_COUNT=0
    
    for TEST_URL in $TEST_URLS; do
        URL_COUNT=$((URL_COUNT + 1))
        START_TIME=$(date +%s%N)
        if curl -I -s -m 10 --socks5 127.0.0.1:$NEW_PORT "$TEST_URL" >/dev/null 2>&1; then
            END_TIME=$(date +%s%N)
            RESPONSE_TIME=$(( (END_TIME - START_TIME) / 1000000 ))
            TOTAL_TIME=$((TOTAL_TIME + RESPONSE_TIME))
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            echo "  ✅ $TEST_URL: ${RESPONSE_TIME}ms"
        else
            echo "  ❌ $TEST_URL: 超时"
        fi
        sleep 1
    done
    
    # 记录节点状态
    SUCCESS_RATE=$((SUCCESS_COUNT * 100 / URL_COUNT))
    node_success_rates[$NODE]=$SUCCESS_RATE
    
    if [ $SUCCESS_COUNT -gt 0 ]; then
        AVG_TIME=$((TOTAL_TIME / SUCCESS_COUNT))
        node_speeds[$NODE]=$AVG_TIME
        echo "  📊 平均响应: ${AVG_TIME}ms, 成功率: ${SUCCESS_RATE}%"
    else
        node_speeds[$NODE]=99999  # 不可用节点给一个很大的值
        echo "  ❌ 节点当前不可用"
    fi
    
    echo ""
done

# 4. 节点排序：先按成功率降序，再按响应时间升序
echo "📊 节点排序（成功率优先，响应时间次之）:"
> /tmp/node_ranking.txt
> /tmp/unavailable_nodes.txt

for NODE in "${!node_speeds[@]}"; do
    DISPLAY_NAME="${node_display_names[$NODE]}"
    SPEED="${node_speeds[$NODE]}"
    SUCCESS_RATE="${node_success_rates[$NODE]}"
    
    if [ $SPEED -ne 99999 ]; then
        # 可用节点：格式为 "成功率 响应时间 节点ID 显示名称"
        printf "%03d %05d %s %s\n" $SUCCESS_RATE $SPEED $NODE "$DISPLAY_NAME" >> /tmp/node_ranking.txt
    else
        # 不可用节点
        echo "000 99999 $NODE $DISPLAY_NAME" >> /tmp/unavailable_nodes.txt
    fi
done

# 排序：先按成功率降序，再按响应时间升序
sort -r /tmp/node_ranking.txt > /tmp/node_ranking_sorted.txt

# 合并文件：可用节点在前（已排序），不可用节点在后
cat /tmp/node_ranking_sorted.txt /tmp/unavailable_nodes.txt > /tmp/all_nodes_sorted.txt

# 显示排序结果
echo "所有节点排序:"
cat /tmp/all_nodes_sorted.txt | while read SUCCESS_RATE SPEED NODE DISPLAY_NAME; do
    if [ $SPEED -eq 99999 ]; then
        echo "  ❌ $DISPLAY_NAME: 不可用"
    else
        echo "  ✅ $DISPLAY_NAME: ${SPEED}ms, 成功率: ${SUCCESS_RATE}%"
    fi
done

# 5. 配置1082服务器（使用节点ID）
echo "🔄 配置SOCKS1082（使用节点ID）..."

# 选择最佳节点作为主节点（成功率最高，响应时间最短）
MAIN_NODE=""
MAIN_DISPLAY=""
MAIN_SPEED=""
MAIN_SUCCESS_RATE=""

# 获取第一个节点（即最佳节点）
if [ -s /tmp/node_ranking_sorted.txt ]; then
    FIRST_LINE=$(head -1 /tmp/node_ranking_sorted.txt)
    MAIN_SUCCESS_RATE=$(echo "$FIRST_LINE" | awk '{print $1}')
    MAIN_SPEED=$(echo "$FIRST_LINE" | awk '{print $2}')
    MAIN_NODE=$(echo "$FIRST_LINE" | awk '{print $3}')
    MAIN_DISPLAY=$(echo "$FIRST_LINE" | awk '{for(i=4;i<=NF;i++) printf $i" "}' | sed 's/ $//')
    echo "✅ 主节点: $MAIN_DISPLAY (${MAIN_SPEED}ms, 成功率: ${MAIN_SUCCESS_RATE}%)"
else
    # 如果没有可用节点，就用第一个节点
    FIRST_LINE=$(head -1 /tmp/all_nodes_sorted.txt)
    MAIN_NODE=$(echo "$FIRST_LINE" | awk '{print $3}')
    MAIN_DISPLAY=$(echo "$FIRST_LINE" | awk '{for(i=4;i<=NF;i++) printf $i" "}' | sed 's/ $//')
    MAIN_SPEED="未知"
    echo "⚠️ 没有可用节点，使用第一个节点: $MAIN_DISPLAY"
fi

# 清空1082的备用节点
uci delete passwall.$NEW_SOCKS.autoswitch_backup_node 2>/dev/null

# 设置主节点（使用节点ID）
uci set passwall.$NEW_SOCKS.node="$MAIN_NODE"

# 将所有其他节点添加到备用列表（使用节点ID）
echo "📋 备用节点列表:"
COUNT=0
while read line; do
    SUCCESS_RATE=$(echo "$line" | awk '{print $1}')
    SPEED=$(echo "$line" | awk '{print $2}')
    NODE=$(echo "$line" | awk '{print $3}')
    DISPLAY_NAME=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf $i" "}' | sed 's/ $//')
    
    # 跳过主节点
    if [ "$NODE" != "$MAIN_NODE" ]; then
        uci add_list passwall.$NEW_SOCKS.autoswitch_backup_node="$NODE"
        COUNT=$((COUNT + 1))
        if [ $SPEED -eq 99999 ]; then
            echo "  $COUNT. ❌ $DISPLAY_NAME"
        else
            echo "  $COUNT. ✅ $DISPLAY_NAME (${SPEED}ms, 成功率: ${SUCCESS_RATE}%)"
        fi
    fi
done < /tmp/all_nodes_sorted.txt

# -------- 新增：处理负载均衡配置段 --------
echo "🔄 处理负载均衡配置段..."
HAPROXY_SECTIONS=""
HAPROXY_INDEX=0

while uci get passwall.@haproxy_config[$HAPROXY_INDEX].lbss >/dev/null 2>&1; do
    HAPROXY_SECTIONS="$HAPROXY_SECTIONS @haproxy_config[$HAPROXY_INDEX]"
    HAPROXY_INDEX=$((HAPROXY_INDEX + 1))
done

HAPROXY_COUNT=$(echo "$HAPROXY_SECTIONS" | wc -w)

if [ $HAPROXY_COUNT -gt 0 ]; then
    echo "  找到负载均衡配置段: $HAPROXY_COUNT 个"
    echo "  可用高性能节点: $(cat /tmp/node_ranking_sorted.txt | wc -l) 个"
    
    # 只使用性能最好的节点来配置负载均衡
    UPDATE_COUNT=$(( $(cat /tmp/node_ranking_sorted.txt | wc -l) < HAPROXY_COUNT ? $(cat /tmp/node_ranking_sorted.txt | wc -l) : HAPROXY_COUNT ))
    echo "  将使用前 $UPDATE_COUNT 个高性能节点配置负载均衡"
    
    NODE_INDEX=1
    for section in $HAPROXY_SECTIONS; do
        if [ $NODE_INDEX -le $UPDATE_COUNT ]; then
            CURRENT_NODE_LINE=$(sed -n "${NODE_INDEX}p" /tmp/node_ranking_sorted.txt)
            CURRENT_NODE_ID=$(echo "$CURRENT_NODE_LINE" | awk '{print $3}')
            CURRENT_NODE_DISPLAY=$(echo "$CURRENT_NODE_LINE" | awk '{for(i=4;i<=NF;i++) printf $i" "}' | sed 's/ $//')
            CURRENT_NODE_SPEED=$(echo "$CURRENT_NODE_LINE" | awk '{print $2}')
            CURRENT_NODE_SUCCESS_RATE=$(echo "$CURRENT_NODE_LINE" | awk '{print $1}')
            
            uci set passwall.$section.lbss="$CURRENT_NODE_ID"
            echo "  ✅ 设置负载均衡配置段 $section 节点为: $CURRENT_NODE_DISPLAY (${CURRENT_NODE_SPEED}ms, 成功率: ${CURRENT_NODE_SUCCESS_RATE}%)"
            NODE_INDEX=$((NODE_INDEX + 1))
        else
            echo "  ⚠️ 跳过配置段 $section (无更多可用高性能节点)"
        fi
    done
else
    echo "  ⚠️ 未找到负载均衡配置段，跳过负载均衡更新"
fi

uci commit passwall

echo ""
echo "✅ SOCKS1082配置完成！"
echo "🎯 主节点: $MAIN_DISPLAY (${MAIN_SPEED}ms, 成功率: ${MAIN_SUCCESS_RATE}%)"
echo "📦 备用节点: $COUNT 个"
echo "⚖️ 负载均衡节点: $((NODE_INDEX - 1)) 个"
echo "🌐 使用端口: 1082"

# 验证最终配置
echo "🔍 验证最终配置..."
FINAL_MAIN_NODE=$(uci get passwall.$NEW_SOCKS.node)
FINAL_BACKUP_NODES=$(uci get passwall.$NEW_SOCKS.autoswitch_backup_node 2>/dev/null)

echo "主节点ID: $FINAL_MAIN_NODE"
echo "主节点显示: $(get_node_display_name "$FINAL_MAIN_NODE")"
echo "备用节点ID列表: $FINAL_BACKUP_NODES"

# 验证负载均衡配置
if [ $HAPROXY_COUNT -gt 0 ]; then
    echo "负载均衡配置:"
    UPDATED_COUNT=0
    for section in $HAPROXY_SECTIONS; do
        HAPROXY_NODE=$(uci get passwall.$section.lbss 2>/dev/null)
        if [ -n "$HAPROXY_NODE" ]; then
            HAPROXY_DISPLAY=$(get_node_display_name "$HAPROXY_NODE")
            echo "  $section: $HAPROXY_DISPLAY"
            UPDATED_COUNT=$((UPDATED_COUNT + 1))
        fi
    done
    echo "  已更新配置段: $UPDATED_COUNT 个"
fi

# 清理
rm -f /tmp/node_ranking.txt /tmp/unavailable_nodes.txt /tmp/all_nodes_sorted.txt /tmp/node_ranking_sorted.txt
