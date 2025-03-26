#!/bin/zsh


kubectl kustomize --enable-helm infra/controllers/cert-manager | kubectl apply -f -
# kubectl apply -k infra/network/gateway
kustomize build --enable-helm infra/controllers/argocd | kubectl apply -f -
kubectl apply -k infra
kubectl apply -k sets
# kubectl apply -k infra/network
# kubectl apply -k infra/network/cloudflared
# kubectl apply -k infra/controllers
kubectl apply -k apps

# kubectl apply -k apps/external
# kubectl apply -k apps/external/proxmox
# kubectl apply -k apps/typesense
