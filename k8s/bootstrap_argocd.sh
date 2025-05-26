#!/bin/zsh

kustomize build --enable-helm infra/controllers/argocd | kubectl apply -f -
kubectl apply -k infra
kubectl apply -k sets
kubectl apply -k apps
