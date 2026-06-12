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
# TRUY VẤN ELASTICSEARCH
# ==========================================

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
        }
      ],
      "should": [
        { "term": { "log_level.keyword": "ERROR" } },
        { "term": { "log_level.keyword": "error" } },
        { "term": { "log_level.keyword": "WARN"  } },
        { "term": { "log_level.keyword": "warn"  } }
      ],
      "minimum_should_match": 1
    }
  },
  "aggs": {
    "by_level": {
      "terms": {
        "field": "log_level.keyword",
        "size": 20
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

  local resp
  resp=$(curl -s -k -u "$ES_USER:$ES_PASS" --cacert "$CA_CERT" \
          -H 'Content-Type: application/json' \
          -X GET "$ES_URL/$index_pattern/_search" -d "$ES_QUERY")

  # Dùng terms agg để đếm chính xác từng giá trị, rồi cộng lại
  # Tránh bị miss do filter agg chỉ match exact value
  local error_count warn_count total
  error_count=$(jq '[
    (.aggregations.by_level.buckets[] | 
     select(.key == "ERROR" or .key == "error") | 
     .doc_count)
  ] | add // 0' <<<"$resp")

  warn_count=$(jq '[
    (.aggregations.by_level.buckets[] | 
     select(.key == "WARN" or .key == "warn") | 
     .doc_count)
  ] | add // 0' <<<"$resp")

  total=$(( error_count + warn_count ))

  if (( total > 0 )); then
    local now_utc log_link text icon

    if (( error_count > 0 )) || (( warn_count > 20 )); then
      now_utc="$(date -u +"%Y-%m-%d %H:%M:%SZ")"

      log_link="${KIBANA_URL}/app/discover#/?_g=(filters:!(),refreshInterval:(pause:!t,value:60000),time:(from:now-5m,to:now))&_a=(dataSource:(type:esql),filters:!(),interval:auto,query:(esql:'FROM%20${prefix}-*%20%7C%20WHERE%20to_string(log_level)%20IN%20(%22ERROR%22%2C%20%22WARN%22%2C%20%22error%22%2C%20%22warn%22)'),sort:!())"

      icon="⚠️"
      if (( error_count > 0 )); then
        icon="🚨"
      fi

      text="${icon} <b>[MONITORING - $prefix]</b> Phát hiện bất thường vượt ngưỡng!

🔴 <b>ERROR:</b> <code>${error_count}</code> log lỗi
🟡 <b>WARN:</b> <code>${warn_count}</code> log cảnh báo

Thời gian hệ thống: ${now_utc} UTC
<a href=\"${log_link}\">Vào Kibana kiểm tra chi tiết tại đây</a>"

      # Fix: tách riêng text ra biến rồi mới gửi, tránh conflict giữa -d và --data-urlencode
      curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true" \
        --data-urlencode "text=${text}" >/dev/null

      echo "[OK] $prefix => SENT ALERT: ERROR=$error_count, WARN=$warn_count"
    else
      echo "[INFO] $prefix => Hệ thống bình thường (ERROR=$error_count, WARN=$warn_count)"
    fi
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
