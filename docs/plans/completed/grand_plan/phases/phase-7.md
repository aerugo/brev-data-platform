# Phase 7: Observability Stack

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Deploy a complete observability stack for monitoring GPU utilization, application metrics, and centralized logging. The stack includes Prometheus for metrics collection, DCGM Exporter for NVIDIA GPU metrics, Loki for log aggregation, Promtail for log shipping, and Grafana for visualization.

---

## Invariants Enforced in This Phase

- **INV-K001**: Namespace per application - Observability services in `monitoring` namespace
- **INV-K002**: Resource limits on all pods - All monitoring pods have resource limits
- **INV-K005**: No `latest` image tags - All images use specific versions
- **NEW INV-O001**: GPU metrics via DCGM Exporter - All GPU workloads must be observable
- **NEW INV-O002**: Centralized logging - All pod logs aggregated to Loki
- **NEW INV-K006**: Sync wave ordering - Observability (wave 1) alongside Storage

---

## Prerequisites

1. RKE2 cluster running (from Phase 3)
2. ArgoCD deployed (from Phase 4)
3. NVIDIA GPU drivers and device plugin working
4. Storage layer (Phase 5) for persistent metrics/logs (optional but recommended)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Monitoring Namespace                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐   │
│  │    Prometheus   │────▶│     Grafana     │◀────│      Loki       │   │
│  │  (Metrics Store)│     │ (Visualization) │     │  (Log Store)    │   │
│  └────────┬────────┘     └─────────────────┘     └────────▲────────┘   │
│           │                                               │             │
│           │ scrapes                                       │ pushes      │
│           ▼                                               │             │
│  ┌─────────────────┐     ┌─────────────────┐     ┌───────┴─────────┐   │
│  │  DCGM Exporter  │     │  Node Exporter  │     │    Promtail     │   │
│  │  (GPU Metrics)  │     │ (System Metrics)│     │  (Log Shipper)  │   │
│  └─────────────────┘     └─────────────────┘     └─────────────────┘   │
│                                                                          │
│  ┌─────────────────┐     ┌─────────────────┐                           │
│  │kube-state-metrics│     │  Alertmanager  │                           │
│  │  (K8s Metrics)  │     │   (Optional)    │                           │
│  └─────────────────┘     └─────────────────┘                           │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Files to Create

### Helm Chart Structure

```
k8s/apps/monitoring/
├── Chart.yaml
├── values.yaml
├── values-dev.yaml
├── templates/
│   ├── namespace.yaml
│   ├── prometheus/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── configmap.yaml
│   │   └── pvc.yaml
│   ├── grafana/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── configmap-datasources.yaml
│   │   └── configmap-dashboards.yaml
│   ├── loki/
│   │   ├── statefulset.yaml
│   │   ├── service.yaml
│   │   └── configmap.yaml
│   ├── promtail/
│   │   ├── daemonset.yaml
│   │   └── configmap.yaml
│   └── dcgm-exporter/
│       ├── daemonset.yaml
│       └── service.yaml
└── dashboards/
    ├── gpu-metrics.json
    ├── kubernetes-cluster.json
    └── dagster-pipelines.json
```

### k8s/apps/monitoring/Chart.yaml

```yaml
apiVersion: v2
name: monitoring
description: Observability stack for brev-data-platform (Prometheus, Grafana, Loki, DCGM)
type: application
version: 0.1.0
appVersion: "1.0.0"

dependencies:
  - name: kube-prometheus-stack
    version: "55.5.0"
    repository: https://prometheus-community.github.io/helm-charts
    condition: prometheus.enabled
  - name: loki
    version: "5.42.0"
    repository: https://grafana.github.io/helm-charts
    condition: loki.enabled
  - name: promtail
    version: "6.15.0"
    repository: https://grafana.github.io/helm-charts
    condition: promtail.enabled
```

### k8s/apps/monitoring/values.yaml

```yaml
# Observability Stack for brev-data-platform
# Configured for H200 GPU monitoring with DCGM Exporter

# Namespace
namespace: monitoring

# Enable/disable components
prometheus:
  enabled: true
grafana:
  enabled: true
loki:
  enabled: true
promtail:
  enabled: true
dcgmExporter:
  enabled: true
alertmanager:
  enabled: false  # Enable when alerting is needed

# kube-prometheus-stack configuration
kube-prometheus-stack:
  # Grafana (managed by kube-prometheus-stack)
  grafana:
    enabled: true
    adminPassword: ""  # Set via secret
    persistence:
      enabled: true
      size: 10Gi

    # Additional data sources
    additionalDataSources:
      - name: Loki
        type: loki
        url: http://loki:3100
        access: proxy
        isDefault: false

    # Pre-configured dashboards
    dashboardProviders:
      dashboardproviders.yaml:
        apiVersion: 1
        providers:
          - name: 'custom'
            orgId: 1
            folder: 'Brev Data Platform'
            type: file
            disableDeletion: false
            editable: true
            options:
              path: /var/lib/grafana/dashboards/custom

    # Resource limits
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi

  # Prometheus
  prometheus:
    prometheusSpec:
      retention: 15d
      retentionSize: 50GB

      # Storage
      storageSpec:
        volumeClaimTemplate:
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 50Gi

      # Resource limits
      resources:
        requests:
          cpu: 500m
          memory: 2Gi
        limits:
          cpu: 2000m
          memory: 4Gi

      # Additional scrape configs for DCGM
      additionalScrapeConfigs:
        - job_name: 'dcgm-exporter'
          kubernetes_sd_configs:
            - role: endpoints
              namespaces:
                names:
                  - monitoring
          relabel_configs:
            - source_labels: [__meta_kubernetes_service_name]
              action: keep
              regex: dcgm-exporter

  # Alertmanager (optional)
  alertmanager:
    enabled: false

  # Node Exporter for system metrics
  nodeExporter:
    enabled: true

  # kube-state-metrics for K8s object metrics
  kubeStateMetrics:
    enabled: true

# Loki configuration (log aggregation)
loki:
  loki:
    auth_enabled: false

    # Storage configuration
    storage:
      type: filesystem

    # Compactor for retention
    compactor:
      retention_enabled: true
      retention_delete_delay: 2h
      delete_request_store: filesystem

    # Limits
    limits_config:
      retention_period: 168h  # 7 days
      max_query_length: 721h
      max_query_parallelism: 32

  # Single binary mode for simplicity
  deploymentMode: SingleBinary
  singleBinary:
    replicas: 1
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 1Gi

    persistence:
      enabled: true
      size: 50Gi

  # Disable other components in single binary mode
  backend:
    replicas: 0
  read:
    replicas: 0
  write:
    replicas: 0

# Promtail configuration (log shipping)
promtail:
  config:
    clients:
      - url: http://loki:3100/loki/api/v1/push

    snippets:
      pipelineStages:
        - cri: {}
        - multiline:
            firstline: '^\d{4}-\d{2}-\d{2}'
            max_wait_time: 3s
        - json:
            expressions:
              level: level
              msg: msg
        - labels:
            level:

  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

# DCGM Exporter for GPU metrics
dcgmExporter:
  image:
    repository: nvcr.io/nvidia/k8s/dcgm-exporter
    tag: "3.3.5-3.4.0-ubuntu22.04"
    pullPolicy: IfNotPresent

  # Run on GPU nodes only
  nodeSelector:
    nvidia.com/gpu.present: "true"

  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule

  # Metrics to collect
  arguments:
    - "-f"
    - "/etc/dcgm-exporter/dcp-metrics-included.csv"

  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi

  service:
    port: 9400
    annotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "9400"

# Service configuration
service:
  grafana:
    type: ClusterIP
    port: 3000
  prometheus:
    type: ClusterIP
    port: 9090
  loki:
    type: ClusterIP
    port: 3100
```

### k8s/apps/monitoring/values-dev.yaml

```yaml
# Development environment overrides
# Reduced resource requirements for dev

kube-prometheus-stack:
  grafana:
    persistence:
      enabled: false  # Use emptyDir for dev
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi

  prometheus:
    prometheusSpec:
      retention: 3d
      retentionSize: 10GB
      storageSpec:
        volumeClaimTemplate:
          spec:
            resources:
              requests:
                storage: 10Gi
      resources:
        requests:
          cpu: 200m
          memory: 512Mi
        limits:
          cpu: 1000m
          memory: 2Gi

loki:
  singleBinary:
    persistence:
      enabled: false  # Use emptyDir for dev
      size: 10Gi
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 512Mi

promtail:
  resources:
    requests:
      cpu: 25m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi
```

### k8s/apps/monitoring/templates/dcgm-exporter/daemonset.yaml

```yaml
{{- if .Values.dcgmExporter.enabled }}
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dcgm-exporter
  namespace: {{ .Values.namespace }}
  labels:
    app: dcgm-exporter
    app.kubernetes.io/name: dcgm-exporter
    app.kubernetes.io/component: gpu-metrics
spec:
  selector:
    matchLabels:
      app: dcgm-exporter
  template:
    metadata:
      labels:
        app: dcgm-exporter
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9400"
    spec:
      {{- with .Values.dcgmExporter.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.dcgmExporter.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: dcgm-exporter
          image: "{{ .Values.dcgmExporter.image.repository }}:{{ .Values.dcgmExporter.image.tag }}"
          imagePullPolicy: {{ .Values.dcgmExporter.image.pullPolicy }}
          args:
            {{- toYaml .Values.dcgmExporter.arguments | nindent 12 }}
          ports:
            - name: metrics
              containerPort: 9400
              protocol: TCP
          resources:
            {{- toYaml .Values.dcgmExporter.resources | nindent 12 }}
          securityContext:
            runAsNonRoot: false
            runAsUser: 0
            capabilities:
              add:
                - SYS_ADMIN
          volumeMounts:
            - name: pod-gpu-resources
              mountPath: /var/lib/kubelet/pod-resources
              readOnly: true
      volumes:
        - name: pod-gpu-resources
          hostPath:
            path: /var/lib/kubelet/pod-resources
{{- end }}
```

### k8s/apps/monitoring/templates/dcgm-exporter/service.yaml

```yaml
{{- if .Values.dcgmExporter.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: dcgm-exporter
  namespace: {{ .Values.namespace }}
  labels:
    app: dcgm-exporter
  annotations:
    {{- with .Values.dcgmExporter.service.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  type: ClusterIP
  ports:
    - port: {{ .Values.dcgmExporter.service.port }}
      targetPort: metrics
      protocol: TCP
      name: metrics
  selector:
    app: dcgm-exporter
{{- end }}
```

### k8s/apps/monitoring/dashboards/gpu-metrics.json

```json
{
  "annotations": {
    "list": []
  },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "liveNow": false,
  "panels": [
    {
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisCenteredZero": false,
            "axisColorMode": "text",
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 10,
            "gradientMode": "none",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "lineInterpolation": "linear",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "never",
            "spanNulls": false,
            "stacking": {
              "group": "A",
              "mode": "none"
            },
            "thresholdsStyle": {
              "mode": "off"
            }
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "red",
                "value": 80
              }
            ]
          },
          "unit": "percent"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 0
      },
      "id": 1,
      "options": {
        "legend": {
          "calcs": ["mean", "max"],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "single",
          "sort": "none"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "DCGM_FI_DEV_GPU_UTIL",
          "legendFormat": "GPU {{gpu}} - {{UUID}}",
          "refId": "A"
        }
      ],
      "title": "GPU Utilization",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisCenteredZero": false,
            "axisColorMode": "text",
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 10,
            "gradientMode": "none",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "lineInterpolation": "linear",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "never",
            "spanNulls": false,
            "stacking": {
              "group": "A",
              "mode": "none"
            },
            "thresholdsStyle": {
              "mode": "off"
            }
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "bytes"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 0
      },
      "id": 2,
      "options": {
        "legend": {
          "calcs": ["mean", "max"],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "single",
          "sort": "none"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "DCGM_FI_DEV_FB_USED",
          "legendFormat": "GPU {{gpu}} - Used",
          "refId": "A"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "DCGM_FI_DEV_FB_FREE",
          "legendFormat": "GPU {{gpu}} - Free",
          "refId": "B"
        }
      ],
      "title": "GPU Memory (FB) Usage",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisCenteredZero": false,
            "axisColorMode": "text",
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 10,
            "gradientMode": "none",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "lineInterpolation": "linear",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "never",
            "spanNulls": false,
            "stacking": {
              "group": "A",
              "mode": "none"
            },
            "thresholdsStyle": {
              "mode": "off"
            }
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "celsius"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 8
      },
      "id": 3,
      "options": {
        "legend": {
          "calcs": ["mean", "max"],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "single",
          "sort": "none"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "DCGM_FI_DEV_GPU_TEMP",
          "legendFormat": "GPU {{gpu}} Temperature",
          "refId": "A"
        }
      ],
      "title": "GPU Temperature",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisCenteredZero": false,
            "axisColorMode": "text",
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 10,
            "gradientMode": "none",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "lineInterpolation": "linear",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "never",
            "spanNulls": false,
            "stacking": {
              "group": "A",
              "mode": "none"
            },
            "thresholdsStyle": {
              "mode": "off"
            }
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "watt"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 8
      },
      "id": 4,
      "options": {
        "legend": {
          "calcs": ["mean", "max"],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "single",
          "sort": "none"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "DCGM_FI_DEV_POWER_USAGE",
          "legendFormat": "GPU {{gpu}} Power",
          "refId": "A"
        }
      ],
      "title": "GPU Power Usage",
      "type": "timeseries"
    }
  ],
  "refresh": "10s",
  "schemaVersion": 38,
  "style": "dark",
  "tags": ["gpu", "nvidia", "dcgm"],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-1h",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "",
  "title": "NVIDIA GPU Metrics",
  "uid": "gpu-metrics",
  "version": 1
}
```

---

## Step 5.5.1: Create Monitoring Namespace

```bash
kubectl create namespace monitoring
```

---

## Step 5.5.2: Add Helm Repositories

```bash
# Add Prometheus community charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

# Add Grafana charts (for Loki and Promtail)
helm repo add grafana https://grafana.github.io/helm-charts

# Update repos
helm repo update
```

---

## Step 5.5.3: Deploy Observability Stack

```bash
# Update dependencies
helm dependency update k8s/apps/monitoring

# Deploy the stack
helm upgrade --install monitoring k8s/apps/monitoring \
  -n monitoring \
  -f k8s/apps/monitoring/values.yaml \
  -f k8s/apps/monitoring/values-dev.yaml

# Watch pods come up
kubectl get pods -n monitoring -w
```

---

## Step 5.5.4: Verify Prometheus

```bash
# Port forward Prometheus
kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090

# Check targets (should include dcgm-exporter)
# Open http://localhost:9090/targets

# Query GPU metrics
curl -s "http://localhost:9090/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL" | jq
```

---

## Step 5.5.5: Verify Grafana

```bash
# Port forward Grafana
kubectl port-forward svc/monitoring-grafana -n monitoring 3001:80

# Get admin password
kubectl get secret monitoring-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d

# Access http://localhost:3001
# Login: admin / <password from above>
```

---

## Step 5.5.6: Verify Loki and Promtail

```bash
# Check Promtail pods
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail

# Check Loki pod
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki

# Query Loki via Grafana Explore or API
curl -s "http://localhost:3100/loki/api/v1/labels" | jq
```

---

## Step 5.5.7: Verify DCGM Exporter

```bash
# Check DCGM exporter pods
kubectl get pods -n monitoring -l app=dcgm-exporter

# Get metrics directly from DCGM exporter
kubectl port-forward daemonset/dcgm-exporter -n monitoring 9400:9400
curl -s http://localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL

# Expected output (on GPU node):
# DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-xxx..."} 0
```

---

## Step 5.5.8: Import GPU Dashboard

1. Open Grafana UI at http://localhost:3001
2. Go to Dashboards → Import
3. Upload `k8s/apps/monitoring/dashboards/gpu-metrics.json`
4. Or use Dashboard ID: `12239` (NVIDIA DCGM Exporter Dashboard)

---

## Add to ArgoCD App-of-Apps

Update `k8s/apps/argocd-apps/templates/monitoring.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_ORG/brev-data-platform.git
    targetRevision: HEAD
    path: k8s/apps/monitoring
    helm:
      valueFiles:
        - values.yaml
        - values-dev.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## Validation Approach

```bash
# Full validation script
echo "=== Observability Stack Validation ==="

echo "1. Namespace exists:"
kubectl get ns monitoring

echo "2. All pods running:"
kubectl get pods -n monitoring

echo "3. Prometheus scrape targets:"
kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090 &
sleep 3
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | length'

echo "4. GPU metrics available:"
curl -s "http://localhost:9090/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL" | jq '.data.result | length'

echo "5. Loki receiving logs:"
curl -s "http://localhost:3100/loki/api/v1/labels" | jq

echo "6. Grafana accessible:"
curl -s -o /dev/null -w "%{http_code}" http://localhost:3001/api/health

echo "=== Validation Complete ==="
```

---

## Troubleshooting

### DCGM Exporter Not Starting

1. Verify GPU node has nvidia driver:
   ```bash
   kubectl debug node/<node-name> -it --image=ubuntu -- nvidia-smi
   ```

2. Check DCGM exporter logs:
   ```bash
   kubectl logs -n monitoring daemonset/dcgm-exporter
   ```

3. Verify kubelet pod resources API:
   ```bash
   ls /var/lib/kubelet/pod-resources
   ```

### Prometheus Not Scraping DCGM

1. Check ServiceMonitor exists:
   ```bash
   kubectl get servicemonitor -n monitoring
   ```

2. Verify scrape config:
   ```bash
   kubectl get secret prometheus-monitoring-kube-prometheus-prometheus -n monitoring -o jsonpath='{.data.prometheus\.yaml\.gz}' | base64 -d | gunzip | grep dcgm
   ```

### Loki Not Receiving Logs

1. Check Promtail config:
   ```bash
   kubectl get configmap -n monitoring -l app.kubernetes.io/name=promtail -o yaml
   ```

2. Check Promtail logs:
   ```bash
   kubectl logs -n monitoring daemonset/monitoring-promtail
   ```

---

## Completion Criteria

- [ ] Monitoring namespace created
- [ ] Prometheus running and scraping targets
- [ ] DCGM Exporter running on GPU node
- [ ] GPU metrics visible in Prometheus
- [ ] Grafana accessible with dashboards
- [ ] Loki receiving logs
- [ ] Promtail shipping logs from all namespaces
- [ ] GPU dashboard imported and showing metrics
- [ ] ArgoCD application for monitoring is synced

---

## Key Metrics to Monitor

### GPU Metrics (via DCGM Exporter)

| Metric | Description |
|--------|-------------|
| `DCGM_FI_DEV_GPU_UTIL` | GPU utilization percentage |
| `DCGM_FI_DEV_FB_USED` | GPU memory used (bytes) |
| `DCGM_FI_DEV_FB_FREE` | GPU memory free (bytes) |
| `DCGM_FI_DEV_GPU_TEMP` | GPU temperature (Celsius) |
| `DCGM_FI_DEV_POWER_USAGE` | GPU power usage (Watts) |
| `DCGM_FI_DEV_SM_CLOCK` | SM clock frequency (MHz) |
| `DCGM_FI_DEV_MEM_CLOCK` | Memory clock frequency (MHz) |

### Kubernetes Metrics

| Metric | Description |
|--------|-------------|
| `container_cpu_usage_seconds_total` | CPU usage per container |
| `container_memory_usage_bytes` | Memory usage per container |
| `kube_pod_status_phase` | Pod status |
| `kube_deployment_status_replicas` | Deployment replica count |

---

## Makefile Targets

Add to `Makefile`:

```makefile
# Observability
.PHONY: port-forward-grafana port-forward-prometheus port-forward-loki

port-forward-grafana:
	@echo "Grafana available at http://localhost:3001"
	kubectl port-forward svc/monitoring-grafana -n monitoring 3001:80

port-forward-prometheus:
	@echo "Prometheus available at http://localhost:9090"
	kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090

port-forward-loki:
	@echo "Loki available at http://localhost:3100"
	kubectl port-forward svc/loki -n monitoring 3100:3100

grafana-password:
	@kubectl get secret monitoring-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d && echo
```

---

## Next Phase

Once the observability stack is running, proceed to [Phase 8: Data Platform (Dagster + Marimo)](phase-8.md).
