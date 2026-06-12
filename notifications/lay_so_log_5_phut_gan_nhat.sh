#!/usr/bin/env bash
set -euo pipefail

# Elasticsearch Config
ES_URL="https://100.113.115.67:9200"
ES_USER="elastic"
ES_PASS="111111"
CA_CERT="/etc/elasticsearch/certs/http_ca.crt"

# Telegram Bot Config
BOT_TOKEN="8962874008:AAEzDeKULbeKcHjnZBy-MASLLaSQ9qinbJE"
CHAT_ID="-5246393269" # Nếu vẫn không nhận, hãy thử đổi thành "-1005246393269"

# Kibana URL
KIBANA_URL="http://100.113.115.67:5601"

# Map DataView IDs
declare -A DATA_VIEW_MAP=(
  ["k8s-logs"]="a029d702-6e49-42ac-ae30-e1408fd64821"
  ["k8s-events"]="d0be76b2-7c0d-47b0-a8bf-4156acb8c487"
)

# Elasticsearch Query
ES_QUERY='{
  "size": 0,
  "track_total_hits": true,
  "query": { "range": { "@timestamp": { "gte": "now-5m", "lt": "now" } } }
}'

check_and_notify() {
  local prefix="$1"
  local dataview_id="${DATA_VIEW_MAP[$prefix]}"
  local index_pattern="${prefix}-*"

  local resp total
  resp=$(curl -s -k -u "$ES_USER:$ES_PASS" --cacert "$CA_CERT" \
          -H 'Content-Type: application/json' \
          -X GET "$ES_URL/$index_pattern/_search" -d "$ES_QUERY")
  
  total=$(jq -r '.hits.total.value // 0' <<<"$resp")

  if (( total > 0 )); then
    local now_utc log_link text
    now_utc="$(date -u +"%Y-%m-%d %H:%M:%SZ")"

    # URL Kibana giữ nguyên
    log_link="${KIBANA_URL}/app/discover#/?_g=(filters:!(),refreshInterval:(pause:!t,value:60000),time:(from:now-5m,to:now))&_a=(dataSource:(type:esql),filters:!(),interval:auto,query:(esql:'FROM%20${prefix}-*'),sort:!())"

    # Chuyển nội dung tin nhắn sang định dạng HTML (Dùng thẻ <b> và <a href="...">)
    text="<b>[$prefix]</b> Có <b>${total}</b> log trong 5 phút gần nhất (tính đến ${now_utc} UTC)
👉 <a href=\"${log_link}\">Nhấn vào đây để xem chi tiết trên Kibana</a>"

    # Gửi sang Telegram với parse_mode=HTML để không bao giờ lỗi kí tự đặc biệt
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${CHAT_ID}" \
      -d "parse_mode=HTML" \
      --data-urlencode "text=${text}" \
      -d "disable_web_page_preview=true" >/dev/null

    echo "[OK] $prefix => sent: total=$total"
  else
    echo "[INFO] $prefix => no logs in last 5m"
  fi
}

for prefix in "${!DATA_VIEW_MAP[@]}"; do
  check_and_notify "$prefix"
done
