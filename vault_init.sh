#!/bin/bash

set -euo pipefail

# Config
NAMESPACE="vault"
VAULT_POD="vault-0"
VAULT_SECRET_PATH="secrets"
DB_SECRET_NAME="DBSECRETS"
DB_USER=""
DB_PASSWORD=""
DB_NAME=""
CLUSTER_KEYS_FILE="cluster-keys.json"

echo "🔐 Initializing Vault..."
kubectl exec vault-0 -n vault -- vault operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json > "$CLUSTER_KEYS_FILE"

echo "📁 Vault keys saved to $CLUSTER_KEYS_FILE"

# Extract keys

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "$CLUSTER_KEYS_FILE")
VAULT_ROOT_TOKEN=$(jq -r '.root_token' "$CLUSTER_KEYS_FILE")

echo "🔓 Unsealing Vault..."
kubectl exec "$VAULT_POD" -n "$NAMESPACE" -- vault operator unseal "$UNSEAL_KEY"

echo "🔐 Logging into Vault..."
kubectl exec -it "$VAULT_POD" -n "$NAMESPACE" -- vault login "$VAULT_ROOT_TOKEN"

echo "⚙️ Enabling KV Secrets engine at path: $VAULT_SECRET_PATH ..."
kubectl exec "$VAULT_POD" -n "$NAMESPACE" -- vault secrets enable -path="$VAULT_SECRET_PATH" kv-v2

echo "💾 Storing database secrets..."
kubectl exec "$VAULT_POD" -n "$NAMESPACE" -- vault kv put "$VAULT_SECRET_PATH/$DB_SECRET_NAME" \
  POSTGRES_USER="$DB_USER" \
  POSTGRES_PASSWORD="$DB_PASSWORD" \
  POSTGRES_DB="$DB_NAME"

echo "✅ Vault initialization and secret storage complete."
