# Kubernetes Logging Stack

Hướng dẫn xây dựng hệ thống logging cho Kubernetes cluster với **Vector + Elasticsearch + Kibana**.

Đây là tài liệu thực tế được viết dựa trên quá trình triển khai thực tế, bao gồm các lỗi gặp phải và cách xử lý.

---

## Kiến trúc

```
┌─────────────────────────────────────────────────────────┐
│                   Kubernetes Cluster                    │
│                                                         │
│   node1 (Control Plane)        node2 (Worker)           │
│   192.168.122.11               192.168.122.12           │
│                                                         │
│   ┌──────────────────┐         ┌──────────────────┐     │
│   │ Vector (systemd) │         │ Vector (systemd) │     │
│   │                  │         │                  │     │
│   │ /var/log/containers        │ /var/log/containers    │
│   │ journald kubelet │         │ journald kubelet │     │
│   │ journald containerd        │ journald containerd    │
│   │ kubectl events   │         │ (không có events)│     │
│   └────────┬─────────┘         └────────┬─────────┘     │
└────────────┼──────────────────────────  ┼ ──────────────┘
             │   HTTPS + gzip             │
             └──────────────┬─────────────┘
                            ▼
              logging-server (192.168.122.25)
              ┌─────────────────────────────┐
              │  Elasticsearch 9.x (9200)   │
              │  xpack.security.enabled     │
              │  user: elastic / 111111     │
              ├─────────────────────────────┤
              │  Kibana (5601)              │
              └─────────────────────────────┘
```

### Luồng dữ liệu

```
[Nguồn Log]                   [Transform]                [Elasticsearch]
─────────────────────────────────────────────────────────────────────────
Pod logs (/var/log/containers) → log_source = app/ingress/coredns/calico ┐
kubelet.service (journald)     → log_source = kubelet                    ├→ k8s-logs-YYYY.MM.DD
containerd.service (journald)  → log_source = containerd                 ┘

kubectl get events             → event_reason, involved_kind ...         → k8s-events-YYYY.MM.DD
```

---

## Hạ tầng

| VM | Role | IP nội bộ | IP Tailscale |
|---|---|---|---|
| node1 | K8s Control Plane | 192.168.122.11 | 100.112.115.86 |
| node2 | K8s Worker | 192.168.122.12 | 100.77.210.122 |
| logging-server | Elasticsearch + Kibana | 192.168.122.25 | 100.113.115.67 |

**Software versions:**
- Kubernetes: v1.31.x (kubeadm)
- Container runtime: containerd
- Vector: 0.55.0
- Elasticsearch: 9.x
- Kibana: 9.x

---

## Phần 1 — Elasticsearch & Kibana

> Thực hiện trên **logging-server**

### 1.1 Cài Elasticsearch

```bash
sudo -i

# Thêm repo
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] \
  https://artifacts.elastic.co/packages/9.x/apt stable main" \
  | tee /etc/apt/sources.list.d/elastic-9.x.list

apt update && apt install elasticsearch -y
```

### 1.2 Cấu hình Elasticsearch

```bash
nano /etc/elasticsearch/jvm.options
# Sửa:
#   -Xms4g
#   -Xmx4g
```

```bash
nano /etc/elasticsearch/elasticsearch.yml
# Sửa:
cluster.name: elasticsearch-devopseduvn
network.host: 0.0.0.0
http.port: 9200
xpack.security.enabled: true
xpack.monitoring.collection.enabled: true
```

```bash
systemctl start elasticsearch
systemctl enable elasticsearch

# Đặt mật khẩu cho user elastic
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -i
# → Nhập: 111111

# Kiểm tra
curl --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u elastic:111111 https://localhost:9200
```

### 1.3 Cài Kibana

```bash
apt install kibana -y

nano /etc/kibana/kibana.yml
# Sửa:
server.port: 5601
server.host: "0.0.0.0"
server.name: "kibana-devopseduvn"
elasticsearch.hosts: ["https://localhost:9200"]
elasticsearch.ssl.certificateAuthorities: ["/etc/kibana/certs/http_ca.crt"]

# Copy cert
mkdir -p /etc/kibana/certs
cp /etc/elasticsearch/certs/http_ca.crt /etc/kibana/certs/
chown -R kibana:kibana /etc/kibana/certs/

systemctl start kibana
systemctl enable kibana
```

Truy cập: `http://100.113.115.67:5601`

### 1.4 Tạo Index Templates và ILM

```bash
# Chạy script có sẵn trong repo
bash scripts/setup-elasticsearch.sh
```

Script tạo:
- **ILM policy `k8s-logs-policy`**: xóa index sau 7 ngày
- **ILM policy `k8s-events-policy`**: xóa index sau 3 ngày
- **Index template `k8s-logs-*`**: `1 shard, 0 replica, refresh 10s, best_compression`
- **Index template `k8s-events-*`**: `1 shard, 0 replica, refresh 30s, best_compression`

> **Lý do 1 shard, 0 replica:** Elasticsearch chạy 1 node — không có nơi để đặt replica, giữ 1 replica sẽ khiến index ở trạng thái `yellow`. 1 shard là tối thiểu, phù hợp cluster nhỏ.

---

## Phần 2 — Vector trên node1 (Control Plane)

### 2.1 Cài Vector

```bash
ssh mdung11@192.168.122.11
sudo -i

curl -1sLf 'https://repositories.timber.io/public/vector/cfg/setup/bash.deb.sh' \
  | bash
apt install vector -y

vector --version
# vector 0.55.0
```

### 2.2 Copy CA certificate từ logging-server

```bash
# Trên logging-server: copy cert sang node1
scp /etc/elasticsearch/certs/http_ca.crt \
    mdung11@192.168.122.11:/tmp/

# Trên node1
mkdir -p /etc/vector/certs
mv /tmp/http_ca.crt /etc/vector/certs/
```

### 2.3 Cài config

```bash
# Copy file config từ repo
cp configs/vector-node1.yaml /etc/vector/vector.yaml

# Validate
vector validate /etc/vector/vector.yaml
```

### 2.4 Đổi user chạy service sang root

Vector cần đọc `/var/log/containers/` — một số file thuộc sở hữu của root.

```bash
nano /lib/systemd/system/vector.service
```

Tìm section `[Service]`, thêm hoặc sửa:

```ini
[Service]
User=root
Group=root
```

```bash
systemctl daemon-reload
systemctl start vector
systemctl enable vector
systemctl status vector
```

### 2.5 Kiểm tra

```bash
# Xem log realtime
journalctl -u vector -f

# Dấu hiệu hoạt động tốt:
# INFO vector: Vector has started.
# INFO vector::topology::builder: Healthcheck passed.
# INFO source ... Starting file server.
# INFO source ... Starting journalctl.
```

---

## Phần 3 — Vector trên node2 (Worker)

### 3.1 Cài Vector

```bash
ssh mdung11@192.168.122.12
sudo -i

curl -1sLf 'https://repositories.timber.io/public/vector/cfg/setup/bash.deb.sh' \
  | bash
apt install vector -y
```

### 3.2 Copy CA certificate

```bash
# Trên logging-server
scp /etc/elasticsearch/certs/http_ca.crt \
    mdung11@192.168.122.12:/tmp/

# Trên node2
mkdir -p /etc/vector/certs
mv /tmp/http_ca.crt /etc/vector/certs/
```

### 3.3 Cài config

Node2 là worker, không có `kubectl` → không thu thập K8s Events.

```bash
cp configs/vector-node2.yaml /etc/vector/vector.yaml

vector validate /etc/vector/vector.yaml
```

### 3.4 Đổi user và khởi động

```bash
nano /lib/systemd/system/vector.service
# Thêm:
# User=root
# Group=root

systemctl daemon-reload
systemctl start vector
systemctl enable vector
systemctl status vector
```

---

## Phần 4 — Kibana Data Views

Truy cập `http://100.113.115.67:5601`

**Stack Management → Data Views → Create data view**

| | Data View 1 | Data View 2 |
|---|---|---|
| Name | K8s Logs | K8s Events |
| Index pattern | `k8s-logs-*` | `k8s-events-*` |
| Timestamp | `@timestamp` | `@timestamp` |

---

## Phần 5 — Verify toàn bộ hệ thống

### Kiểm tra indices

```bash
# Trên logging-server
curl -sk --cacert /etc/elasticsearch/certs/http_ca.crt \
  -u elastic:111111 \
  "https://localhost:9200/_cat/indices/k8s-*"

# Kết quả mong đợi:
# yellow open k8s-logs-2026.06.02   ... 1 1  9720  0  3.6mb
# yellow open k8s-events-2026.06.02 ... 1 1    18  0  145kb
```

> `yellow` là bình thường với Elasticsearch 1 node — replica không thể assign.

### Kiểm tra Vector trên từng node

```bash
# node1
journalctl -u vector -f

# node2
journalctl -u vector -f
```

### Kibana — Query hay dùng

**Data View: K8s Logs**

```
# Chỉ app logs
log_source : "app"

# Chỉ lỗi
log_level : "ERROR"

# WARN và ERROR
log_level : "WARN" or log_level : "ERROR"

# Kubelet của node cụ thể
log_source : "kubelet" and k8s_node : "node1"

# Ingress logs
log_source : "ingress"

# CoreDNS
log_source : "coredns"

# Theo namespace
k8s_namespace : "demo-logging"

# Theo pod
k8s_pod : "k8s-logging-demo*"

# Login thất bại (app k8s-logging-demo)
action : "LOGIN_FAILED"

# Slow request
duration_ms >= 500
```

**Data View: K8s Events**

```
# Chỉ Warning
event_type : "Warning"

# CrashLoopBackOff
event_reason : "BackOff"

# OOMKilled
event_reason : "OOMKilled"

# Pull image lỗi
event_reason : "Failed" and event_source : "kubelet"

# Theo namespace
involved_namespace : "demo-logging"
```

---

## Cấu trúc Index

### k8s-logs-YYYY.MM.DD

| Field | Type | Mô tả |
|---|---|---|
| `@timestamp` | date | Thời điểm log |
| `log_source` | keyword | `app` / `kubelet` / `containerd` / `ingress` / `coredns` / `calico` / `k8s-system` |
| `log_level` | keyword | `INFO` / `WARN` / `ERROR` |
| `message` | text | Nội dung log |
| `k8s_namespace` | keyword | Kubernetes namespace |
| `k8s_pod` | keyword | Tên pod |
| `k8s_container` | keyword | Tên container |
| `k8s_node` | keyword | Tên node |
| `is_json_log` | boolean | App log có phải JSON không |
| `action` | keyword | Action của app (LOGIN_SUCCESS, ...) |
| `username` | keyword | User thực hiện action |
| `duration_ms` | integer | Thời gian xử lý request |
| `status` | short | HTTP status code |
| `ip` | ip | IP của request |

### k8s-events-YYYY.MM.DD

| Field | Type | Mô tả |
|---|---|---|
| `@timestamp` | date | Thời điểm event |
| `event_type` | keyword | `Normal` / `Warning` |
| `event_reason` | keyword | `BackOff` / `OOMKilled` / `Failed` / ... |
| `event_message` | text | Mô tả chi tiết |
| `event_count` | integer | Số lần lặp lại |
| `event_source` | keyword | Component sinh ra event (`kubelet`, `scheduler`, ...) |
| `involved_kind` | keyword | Loại object (`Pod`, `Node`, `Deployment`, ...) |
| `involved_name` | keyword | Tên object |
| `involved_namespace` | keyword | Namespace của object |
| `log_level` | keyword | `INFO` (Normal) / `WARN` (Warning) |

---


```

---

## Cấu trúc repository

```
k8s-logging-stack/
├── README.md
├── configs/
│   ├── vector-node1.yaml    # Vector config cho control-plane (có K8s Events)
│   └── vector-node2.yaml    # Vector config cho worker (không có K8s Events)
└── scripts/
    └── setup-elasticsearch.sh  # Tạo Index Templates + ILM Policies
```
