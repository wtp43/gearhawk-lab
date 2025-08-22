#!/bin/zsh

kustomize build --enable-helm infra/controllers/argocd | kubectl apply -f -
kubectl apply -k infra
kubectl apply -k sets
kubectl apply -k apps

# metrics server
kubectl apply -f https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/main/deploy/standalone-install.yaml
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
