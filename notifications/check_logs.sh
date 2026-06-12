#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CẤU HÌNH HỆ THỐNG (THAY ĐỔI THEO SERVER CỦA BẠN)
# ==========================================
ES_URL="https://100.113.115.67:9200"
ES_USER="elastic"
ES_PASS="111111"
CA_CERT="/etc/elasticsearch/certs/http_ca.crt"

# Cấu hình Telegram Bot
BOT_TOKEN="8962874008:AAEzDeKULbeKcHjnZBy-MASLLaSQ9qinbJE"
CHAT_ID="-5246393269" # Lưu ý: Nếu không nhận tin, hãy đổi thành "-1005246393269"

# Cấu hình Kibana URL
KIBANA_URL="http://100.113.115.67:5601"

# Danh sách tiền tố Index cần quét (Vòng lặp sẽ duyệt qua các key này)
declare -A DATA_VIEW_MAP=(
  ["k8s-logs"]="a029d702-6e49-42ac-ae30-e1408fd64821"
  ["k8s-events"]="d0be76b2-7c0d-47b0-a8bf-4156acb8c487"
)

# ==========================================
# TRUY VẤN ELASTICSEARCH (CHỈ LỌC LOG ERROR)
# ==========================================
# Sử dụng cấu trúc bool query kết hợp range thời gian 5p

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
          "term": {
            "log_level.keyword": "ERROR"
          }
        }
      ]
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
  # Gọi API tìm kiếm của Elasticsearch kèm chứng chỉ CA nội bộ
  resp=$(curl -s -k -u "$ES_USER:$ES_PASS" --cacert "$CA_CERT" \
          -H 'Content-Type: application/json' \
          -X GET "$ES_URL/$index_pattern/_search" -d "$ES_QUERY")
  
  # Sử dụng jq để bóc tách số lượng bản ghi khớp điều kiện
  total=$(jq -r '.hits.total.value // 0' <<<"$resp")

  if (( total > 0 )); then
    local now_utc log_link text
    now_utc="$(date -u +"%Y-%m-%d %H:%M:%SZ")"

    # Tạo mốc thời gian quá khứ chính xác 5 phút trước theo chuẩn UTC để làm mốc cứng cho Kibana
    local static_from static_to
    static_from=$(date -u -d "5 minutes ago" +"%Y-%m-%dT%H:%M:%S.000Z")
    static_to=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    # URL Kibana ESQL mới: Tự động điền sẵn câu lệnh 'FROM index-* | WHERE ...' để khi click vào là xem được lỗi ngay
    log_link="${KIBANA_URL}/app/discover#/?_g=(filters:!(),refreshInterval:(pause:!t,value:60000),time:(from:'${static_from}',to:'${static_to}'))&_a=(dataSource:(type:esql),filters:!(),interval:auto,query:(esql:'FROM%20${prefix}-*%20%7C%20WHERE%20to_string(log_level)%20%3D%3D%20%22ERROR%22%20or%20contains(message%2C%20%22ERROR%22)'),sort:!())"

    # Xây dựng nội dung thông báo bằng định dạng HTML
    text="🚨 <b>[ALERT - $prefix]</b> Phát hiện <b>${total}</b> log lỗi <b>ERROR</b> trong 5 phút qua!
 Thời gian hệ thống: ${now_utc} UTC
 <a href=\"${log_link}\">Vào Kibana ngay !</a>"

    # Đẩy thông báo sang API Telegram dưới dạng parse_mode=HTML để tránh lỗi nuốt ký tự đặc biệt của URL
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${CHAT_ID}" \
      -d "parse_mode=HTML" \
      --data-urlencode "text=${text}" \
      -d "disable_web_page_preview=true" >/dev/null

    echo "[OK] $prefix => sent alert: total=$total"
  else
    # Đúng yêu cầu của bạn: Nếu không có lỗi, im lặng ghi log thông báo ra terminal
    echo "[INFO] $prefix => no logs error in last 5m"
  fi
}

# ==========================================
# VÒNG LẶP CHÍNH DUYỆT QUA CÁC TIỀN TỐ INDEX
# ==========================================
for prefix in "${!DATA_VIEW_MAP[@]}"; do
  check_and_notify "$prefix"
done
