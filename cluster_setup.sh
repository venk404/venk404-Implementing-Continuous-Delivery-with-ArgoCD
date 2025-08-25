#!/bin/bash

set -e  # Exit if any command fails

CLUSTER_KEYS_FILE="cluster-keys.json"
VAULT_CR_YAML="./External-secrets-app/External-secret-cr.yaml"

echo "🚀 Creating KIND cluster..."
kind create cluster --name multinode-cluster --config ./clusters.yml

echo "🔍 Verifying cluster context..."
kubectl cluster-info --context kind-multinode-cluster

echo "🏷️ Labeling nodes..."
kubectl label nodes multinode-cluster-worker node-role.kubernetes.io/worker=worker
kubectl label nodes multinode-cluster-worker2 node-role.kubernetes.io/worker=worker
kubectl label nodes multinode-cluster-worker3 node-role.kubernetes.io/worker=worker

kubectl label node multinode-cluster-worker2 type=database
kubectl label node multinode-cluster-worker type=application
kubectl label node multinode-cluster-worker3 type=dependent_services

echo "📋 Nodes and labels:"
kubectl get nodes --show-labels

kubectl cluster-info --context kind-multinode-cluster

echo "📦 Creating 'argocd' namespace..."
kubectl create ns argocd

echo "➕ Adding ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update


echo "📥 Installing ArgoCD..."
helm install argocd argo/argo-cd -n argocd --values ./argocd-values.yaml

echo "🔍 Waiting for ArgoCD pods to be Running and Ready..."

# Wait loop for all ArgoCD pods to be ready
while true; do
  POD_JSON=$(kubectl get pods -n argocd -o json 2>/dev/null || true)
  POD_COUNT=$(echo "$POD_JSON" | jq '.items | length')

  if [[ "$POD_COUNT" -eq 0 ]]; then
    echo "ℹ️ No pods found in 'argocd' namespace yet. Waiting..."
    sleep 5
    continue
  fi

  NOT_READY=$(echo "$POD_JSON" | jq -r '
    .items[] |
    select(
      .status.phase != "Running"
      or (.status.containerStatuses // [] | map(select(.ready != true)) | length > 0)
    ) |
    .metadata.name
  ')

  if [[ -z "$NOT_READY" ]]; then
    echo "✅ All ArgoCD pods are Running and Ready."
    break
  else
    echo "⏳ Waiting for the following ArgoCD pod(s) to be ready:"
    echo "$NOT_READY"
    sleep 5
  fi
done

echo "📄 Applying Vault application manifest..."

kubectl create ns vault
kubectl apply -f ./Vault-app/Vault_application.yaml

echo "✅ ArgoCD is ready, and Vault application has been applied."
echo "⏳ Waiting for Vault pod to be in 'Running' state..."


echo "⏳ Waiting for Vault pod to be created..."

# Wait for the Vault pod to exist
while true; do
  if kubectl get pod -n vault | grep -q "vault"; then
    echo "✅ Vault pod detected."
    break
  fi
  echo "⌛ Vault pod not found yet. Retrying in 5 seconds..."
  sleep 5
done

# Wait until Vault pod shows Running
while true; do
  STATUS=$(kubectl get pod vault-0 -n vault -o jsonpath="{.status.phase}")
  if [[ "$STATUS" == "Running" ]]; then
    echo "✅ Vault pod is in 'Running' state."
    break
  fi
  echo "⏱️ Vault pod status: $STATUS. Retrying in 5 seconds..."
  sleep 5
done

# Automatically run vault_init.sh
echo "🚀 Running vault_init.sh..."
bash "vault_init.sh"


echo "⏳ Waiting for Vault service to become ready..."
while true; do
  READY=$(kubectl get svc vault -n vault --no-headers --ignore-not-found)
  if [[ -n "$READY" ]]; then
    echo "✅ Vault service is available."
    break
  fi
  sleep 5
done


echo "📄 Applying External Secrets CRDs..."
kubectl apply -f ./External-secrets-app/External-secret-crds.yaml

echo "⏳ Waiting for External Secrets pods to be Running..."
while true; do
  PODS=$(kubectl get pods -n external-secrets --no-headers 2>/dev/null || true)

  if [[ -z "$PODS" ]]; then
    echo "ℹ️ Waiting for pods to appear in 'external-secrets' namespace..."
    sleep 5
    continue
  fi

  NOT_READY=$(echo "$PODS" | awk '{print $2}' | grep -vE '^[0-9]+/[0-9]+$' || true)
  INCOMPLETE=$(echo "$PODS" | awk '{print $2}' | grep -vE '^([0-9]+)/\1$' || true)

  if [[ -z "$NOT_READY" && -z "$INCOMPLETE" ]]; then
    echo "✅ All pods in 'external-secrets' namespace are fully Ready."
    break
  else
    echo "⏳ Some pods are not yet fully Ready. Retrying in 5s..."
    sleep 5
  fi
done

echo "🔐 Encoding Vault root token..."
VAULT_ROOT_TOKEN=$(jq -r '.root_token' "$CLUSTER_KEYS_FILE")
ENCODED_TOKEN=$(echo -n "$VAULT_ROOT_TOKEN" | base64)

echo "✍️ Updating $VAULT_CR_YAML with base64-encoded Vault root token..."

yq eval ".spec.source.helm.parameters[] |= select(.name == \"secret.token\").value = \"$ENCODED_TOKEN\"" -i "$VAULT_CR_YAML"
echo "📦 Applying updated External-secret-cr.yaml..."
kubectl apply -f "$VAULT_CR_YAML"

echo "✅ Script complete."


# Step 2: Wait 30 seconds
echo "⏳ Waiting 30 seconds for Vault setup..."
sleep 30


# Step 4: Wait for 'dev-db' secret in 'student-api' namespace
echo "🔍 Waiting for 'dev-db' secret in 'student-api' namespace..."

while true; do
    if kubectl get secret dev-db -n student-api &> /dev/null; then
        echo "✅ Secret 'dev-db' found in 'student-api' namespace."
        break
    else
        echo "⌛ Secret not found yet. Retrying in 5 seconds..."
        sleep 5
    fi
done

# Step 3: Apply Postgres YAML
echo "🐘 Applying Postgres configuration..."

kubectl apply -f ./Postgres-app/Postgres.yaml

echo "⏳ Waiting for PostgreSQL pod to be 'Running' and Ready in 'student-api' namespace..."

while true; do
  POD_JSON=$(kubectl get pods -n student-api -o json 2>/dev/null || true)

  # Filter pods by name pattern (starts with "postgres")
  FILTERED_PODS=$(echo "$POD_JSON" | jq '
    { items: [.items[] | select(.metadata.name | test("^postgres"))] }
  ')

  POD_COUNT=$(echo "$FILTERED_PODS" | jq '.items | length')

  if [[ "$POD_COUNT" -eq 0 ]]; then
    echo "ℹ️ PostgreSQL StatefulSet pod not found yet in 'student-api'. Waiting..."
    sleep 5
    continue
  fi

  # Check if any matching pod is not ready
  NOT_READY=$(echo "$FILTERED_PODS" | jq -r '
    .items[] |
    select(
      .status.phase != "Running"
      or (.status.containerStatuses // [] | map(select(.ready != true)) | length > 0)
    ) |
    .metadata.name
  ')

  if [[ -z "$NOT_READY" ]]; then
    echo "✅ PostgreSQL StatefulSet pod is Running and Ready in 'student-api'."
    break
  else
    echo "⏳ Waiting for PostgreSQL StatefulSet pod(s) to be ready:"
    echo "$NOT_READY"
    sleep 5
  fi
done

echo "🚀 Deploying REST API application..."
kubectl apply -f ./Restapi-app/Restapi.yaml