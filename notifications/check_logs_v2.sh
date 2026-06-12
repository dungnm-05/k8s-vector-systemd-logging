#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CẤU HÌNH HỆ THỐNG
# ==========================================
ES_URL="https://100.113.115.67:9200"
ES_USER="elastic"
ES_PASS="111111"
CA_CERT="/etc/elasticsearch/certs/http_ca.crt"

# Cấu hình Telegram Bot
BOT_TOKEN="8962874008:AAEzDeKULbeKcHjnZBy-MASLLaSQ9qinbJE"
CHAT_ID="-5246393269"

# Cấu hình Kibana URL
KIBANA_URL="http://100.113.115.67:5601"

# Danh sách tiền tố Index cần quét
declare -A DATA_VIEW_MAP=(
  ["k8s-logs"]="a029d702-6e49-42ac-ae30-e1408fd64821"
  ["k8s-events"]="d0be76b2-7c0d-47b0-a8bf-4156acb8c487"
)

# ==========================================
# TRUY VẤN ELASTICSEARCH NÂNG CẤP (CHỐNG LỆCH ĐUÔI CHUỖI)
# ==========================================
# Dùng wildcard và query_string để bắt trọn các biến thể như WARN, WARNING, error, ERROR...
ES_QUERY='{
  "size": 0,
  "track_total_hits": true,
  "query": {
    "bool": {
      "must": [
        {
          "range": {
            "@timestamp": {
              "gte": "now-5m",
              "lt": "now"
            }
          }
        },
        {
          "query_string": {
            "default_field": "log_level",
            "query": "ERROR OR error OR WARN OR warn OR WARNING OR warning"
          }
        }
      ]
    }
  },
  "aggs": {
    "errors": {
      "filter": {
        "query_string": {
          "default_field": "log_level",
          "query": "ERROR OR error"
        }
      }
    },
    "warns": {
      "filter": {
        "query_string": {
          "default_field": "log_level",
          "query": "WARN OR warn OR WARNING OR warning"
        }
      }
    }
  }
}'

# ==========================================
# HÀM XỬ LÝ KIỂM TRA VÀ PHÁT CẢNH BÁO
# ==========================================
check_and_notify() {
  local prefix="$1"
  local index_pattern="${prefix}-*"

  local resp total
  resp=$(curl -s -k -u "$ES_USER:$ES_PASS" --cacert "$CA_CERT" \
          -H 'Content-Type: application/json' \
          -X GET "$ES_URL/$index_pattern/_search" -d "$ES_QUERY")
  
  # Lấy số lượng Error và Warn thực tế từ Aggs để làm chuẩn
  local error_count warn_count
  error_count=$(jq -r '.aggregations.errors.doc_count // 0' <<<"$resp")
  warn_count=$(jq -r '.aggregations.warns.doc_count // 0' <<<"$resp")
  
  # Ép tổng số lượng bằng chính tổng hai loại cộng lại để KHÔNG BAO GIỜ có biến số thứ 3 gây lệch
  total=$((error_count + warn_count))

  if (( total > 0 )); then
    local now_utc log_link text
    now_utc="$(date -u +"%Y-%m-%d %H:%M:%SZ")"

    # URL Kibana ESQL: Đồng bộ cấu trúc contains/like để hốt trọn gói giống script
    log_link="${KIBANA_URL}/app/discover#/?_g=(filters:!(),refreshInterval:(pause:!t,value:60000),time:(from:now-5m,to:now))&_a=(dataSource:(type:esql),filters:!(),interval:auto,query:(esql:'FROM%20${prefix}-*%20%7C%20WHERE%20contains(to_lower(to_string(log_level))%2C%20%22error%22)%20or%20contains(to_lower(to_string(log_level))%2C%20%22warn%22)'),sort:!())"

    # Xây dựng nội dung tin nhắn HTML
    text="⚠️ <b>[MONITORING - $prefix]</b> Phát hiện bất thường trong 5 phút qua!

🚨 <b>Cấp độ ERROR:</b> <code>${error_count}</code> log lỗi
⚠️ <b>Cấp độ WARN:</b> <code>${warn_count}</code> log cảnh báo

🕒 Thời gian hệ thống: ${now_utc} UTC
👉 <a href=\"${log_link}\">Vào Kibana kiểm tra chi tiết tại đây</a>"

    # Đẩy thông báo sang Telegram
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${CHAT_ID}" \
      -d "parse_mode=HTML" \
      --data-urlencode "text=${text}" \
      -d "disable_web_page_preview=true" >/dev/null

    echo "[OK] $prefix => sent alert: ERROR=$error_count, WARN=$warn_count (Total=$total)"
  else
    echo "[INFO] $prefix => no logs error or warn in last 5m"
  fi
}

# ==========================================
# VÒNG LẶP CHÍNH
# ==========================================
for prefix in "k8s-logs" "k8s-events"; do
  check_and_notify "$prefix"
done
