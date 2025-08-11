# SRE Projects - Setup one-click deployments using ArgoCD

## Problem Statement
We need to configure ArgoCD to do deployments on our behalf. The deployment should be triggered once any code changes are merged into the GitHub repository and the CI pipeline works successfully.

## Prerequisites
- Docker
- Kind
- Kubectl
- Helm (for installing Vault and ESO)
- Kubernetes cluster (from Assignment 6)
- ArgoCD

## Installation Guide

### 1. Install and Set Up ArgoCD
```bash
# Create ArgoCD namespace
kubectl create ns argocd

# Add ArgoCD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm

# Install ArgoCD with custom values
helm install argocd argo/argo-cd -n argocd --values ./argocd-values.yaml

# Verify the installation
kubectl get pods -n argocd -owide
```
### Access the ArgoCD Dashboard

To access the ArgoCD Dashboard, follow the steps below:

### 2. Port Forward to Access the ArgoCD UI
Run the following command to forward the port:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
### 3. Retrieve the Initial Admin Password
To get the initial admin password for ArgoCD, run this command:

```bash
argocd admin initial-password -n argocd
```
Username: admin

Password: Use the initial password retrieved from the above command.

Now, you can log in to the ArgoCD UI at http://localhost:8080/applications using the provided credentials.


### 4. Clone the Repository
```bash
git clone https://github.com/venk404/venk404-Helm-Assignments-k8s.git
cd "Assignment 9"
```

## Vault Setup

### 5. Deploy Vault Server Using ArgoCD
```bash
kubectl apply -f ./Vault-app/Vault_application.yaml
```

### 6. Initialize and Unseal Vault
```bash
# Wait for the Vault-0 pod to reach the ready state
kubectl exec vault-0 -n vault -- vault operator init -key-shares=1 -key-threshold=1 -format=json > cluster-keys.json

# Extract the unseal key
export VAULT_UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' cluster-keys.json)

# Unseal Vault
kubectl exec vault-0 -n vault -- vault operator unseal $VAULT_UNSEAL_KEY
```

### 7. Configure Vault Secrets
```bash
# Login to Vault (extract root token from cluster-keys.json)
export VAULT_ROOT_TOKEN=$(jq -r '.root_token' cluster-keys.json)
kubectl exec -it vault-0 -n vault -- /bin/sh

# Inside the Vault pod
vault login $VAULT_ROOT_TOKEN
vault secrets enable -path=secrets kv-v2
vault kv put secrets/DBSECRETS POSTGRES_PASSWORD=yourpassword POSTGRES_DB=yourdb POSTGRES_USER=youruser
exit
```

### 8. Update Values File for Vault Authentication
```bash
# Encode the Vault token
echo -n $VAULT_ROOT_TOKEN | base64

# Update the External Secrets values file
cd external-secrets
# Edit values.yaml and replace the token with the Base64-encoded value
vi values.yaml
```

## Deploy Applications with ArgoCD

### 9. Create External Secrets Application
```bash
kubectl apply -f ./External-secrets-app/External-secret-crds.yaml
kubectl apply -f ./External-secrets-app/External-secret-cr.yaml
```

### 10. Deploy PostgreSQL Database
```bash
kubectl apply -f ./Postgres-app/Postgres.yaml
```

### 11. Deploy REST API Application
```bash
kubectl apply -f ./Restapi-app/Restapi.yaml
```

### 12. Access the API
The REST API documentation is available at:
```
http://127.0.0.1:30007/docs
```

## Conclusion
This setup successfully deploys a REST API with its dependent services ArgoCD for GitOps-based deployment. The implementation securely manages database credentials through HashiCorp Vault and External Secrets Operator.