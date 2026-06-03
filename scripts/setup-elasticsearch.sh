#!/bin/bash
# setup-elasticsearch.sh
# Chạy trên logging-server sau khi cài Elasticsearch
# Tạo Index Templates và ILM Policies cho k8s-logs-* và k8s-events-*

ES="https://localhost:9200"
CERT="/etc/elasticsearch/certs/http_ca.crt"
AUTH="elastic:111111"

es() {
  local method="$1" path="$2" data="$3" desc="$4"
  echo -n "  $desc ... "
  code=$(curl -s -o /tmp/es_out.json -w "%{http_code}" \
    --cacert "$CERT" -u "$AUTH" \
    -X "$method" "${ES}${path}" \
    -H "Content-Type: application/json" \
    ${data:+-d "$data"})
  [[ "$code" -ge 200 && "$code" -lt 300 ]] && echo "OK ($code)" || { echo "FAIL ($code)"; cat /tmp/es_out.json; echo; }
}

echo "=== Elasticsearch Setup ==="
echo ""

# Kiểm tra kết nối
echo "Cluster health:"
curl -s --cacert "$CERT" -u "$AUTH" "$ES/_cluster/health" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(' status:', d['status'], '| nodes:', d['number_of_nodes'])"
echo ""

# ILM Policy: k8s-logs (7 ngày)
es PUT "/_ilm/policy/k8s-logs-policy" '{
  "policy": {
    "phases": {
      "hot":    { "min_age": "0ms", "actions": { "set_priority": { "priority": 100 } } },
      "delete": { "min_age": "7d",  "actions": { "delete": {} } }
    }
  }
}' "ILM k8s-logs-policy (7 ngày)"

# ILM Policy: k8s-events (3 ngày)
es PUT "/_ilm/policy/k8s-events-policy" '{
  "policy": {
    "phases": {
      "hot":    { "min_age": "0ms", "actions": { "set_priority": { "priority": 50 } } },
      "delete": { "min_age": "3d",  "actions": { "delete": {} } }
    }
  }
}' "ILM k8s-events-policy (3 ngày)"

# Index Template: k8s-logs-*
es PUT "/_index_template/k8s-logs-template" '{
  "index_patterns": ["k8s-logs-*"],
  "priority": 200,
  "template": {
    "settings": {
      "number_of_shards":   1,
      "number_of_replicas": 0,
      "refresh_interval":   "10s",
      "codec":              "best_compression",
      "index.lifecycle.name": "k8s-logs-policy",
      "index.mapping.total_fields.limit": 300,
      "index.mapping.ignore_malformed":   true
    },
    "mappings": {
      "dynamic": "true",
      "_source":  { "enabled": true },
      "properties": {
        "@timestamp":    { "type": "date" },
        "log_source":    { "type": "keyword" },
        "log_level":     { "type": "keyword" },
        "message":       { "type": "text", "fields": { "keyword": { "type": "keyword", "ignore_above": 512 } } },
        "k8s_namespace": { "type": "keyword" },
        "k8s_pod":       { "type": "keyword" },
        "k8s_container": { "type": "keyword" },
        "k8s_node":      { "type": "keyword" },
        "k8s_app":       { "type": "keyword" },
        "service":       { "type": "keyword" },
        "request_id":    { "type": "keyword", "index": false },
        "username":      { "type": "keyword" },
        "action":        { "type": "keyword" },
        "ip":            { "type": "ip", "ignore_malformed": true },
        "status":        { "type": "short" },
        "duration_ms":   { "type": "integer" },
        "is_json_log":   { "type": "boolean" }
      }
    }
  }
}' "Index template k8s-logs-*"

# Index Template: k8s-events-*
es PUT "/_index_template/k8s-events-template" '{
  "index_patterns": ["k8s-events-*"],
  "priority": 200,
  "template": {
    "settings": {
      "number_of_shards":   1,
      "number_of_replicas": 0,
      "refresh_interval":   "30s",
      "codec":              "best_compression",
      "index.lifecycle.name": "k8s-events-policy",
      "index.mapping.total_fields.limit": 50
    },
    "mappings": {
      "_source": { "enabled": true },
      "properties": {
        "@timestamp":         { "type": "date" },
        "log_source":         { "type": "keyword" },
        "log_level":          { "type": "keyword" },
        "message":            { "type": "text" },
        "event_type":         { "type": "keyword" },
        "event_reason":       { "type": "keyword" },
        "event_message":      { "type": "text" },
        "event_count":        { "type": "integer" },
        "event_source":       { "type": "keyword" },
        "involved_kind":      { "type": "keyword" },
        "involved_name":      { "type": "keyword" },
        "involved_namespace": { "type": "keyword" },
        "k8s_namespace":      { "type": "keyword" }
      }
    }
  }
}' "Index template k8s-events-*"

echo ""
echo "=== Verify ==="
curl -s --cacert "$CERT" -u "$AUTH" "$ES/_cat/indices/k8s-*" 2>/dev/null \
  || echo "  (Chưa có index - bình thường nếu Vector chưa chạy)"
echo ""
echo "Done."
