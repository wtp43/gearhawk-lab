Logs Architecture

Your Application
↓

Local OTel Agent (DaemonSet) - http://k8s-infra-otel-agent.signoz.svc.cluster.local:4317

↓

SigNoz Gateway Collector
↓
SigNoz Backend
