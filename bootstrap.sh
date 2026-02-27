#!/usr/bin/env bash
###############################################################################
# Lux GPU CI — one-shot bootstrap.
# Provisions EKS + Karpenter + NVIDIA device plugin + ARC + RunnerScaleSet.
#
# Usage:
#   export AWS_REGION=us-west-2          # default us-west-2
#   export GITHUB_ORG=luxfi              # default luxfi
#   export GITHUB_PAT=ghp_xxxxx          # required: classic PAT with admin:org + repo
#   ./bootstrap.sh                       # full deploy
#   ./bootstrap.sh runners-only          # skip terraform, only redeploy runners
###############################################################################
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

: "${AWS_REGION:=us-west-2}"
: "${GITHUB_ORG:=luxfi}"
: "${CLUSTER_NAME:=lux-gpu-ci}"
: "${KARPENTER_VERSION:=1.0.7}"
: "${ARC_VERSION:=0.9.3}"
: "${NVIDIA_PLUGIN_VERSION:=0.16.2}"

MODE="${1:-full}"

log() { printf "\033[1;36m[bootstrap]\033[0m %s\n" "$*"; }

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required tool: $1" >&2
    exit 1
  }
}

for b in aws terraform kubectl helm envsubst; do
  require_bin "$b"
done

if [[ "$MODE" != "runners-only" ]]; then
  log "terraform init + apply"
  terraform -chdir=terraform init -upgrade
  terraform -chdir=terraform apply -auto-approve \
    -var "region=$AWS_REGION" \
    -var "cluster_name=$CLUSTER_NAME" \
    -var "github_org=$GITHUB_ORG"
fi

log "fetching terraform outputs"
CLUSTER_ENDPOINT=$(terraform -chdir=terraform output -raw cluster_endpoint)
KARPENTER_QUEUE_NAME=$(terraform -chdir=terraform output -raw karpenter_queue_name)
KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir=terraform output -raw karpenter_node_iam_role_name)

log "updating kubeconfig"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

log "installing Karpenter $KARPENTER_VERSION"
helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version "$KARPENTER_VERSION" \
  --namespace kube-system \
  --create-namespace \
  -f <(env \
    CLUSTER_NAME="$CLUSTER_NAME" \
    CLUSTER_ENDPOINT="$CLUSTER_ENDPOINT" \
    KARPENTER_QUEUE_NAME="$KARPENTER_QUEUE_NAME" \
    envsubst < helm/karpenter-values.yaml) \
  --wait

log "applying Karpenter NodePool + EC2NodeClass"
env \
  CLUSTER_NAME="$CLUSTER_NAME" \
  KARPENTER_NODE_IAM_ROLE_NAME="$KARPENTER_NODE_IAM_ROLE_NAME" \
  envsubst < helm/karpenter-nodepool.yaml | kubectl apply -f -

log "installing NVIDIA device plugin $NVIDIA_PLUGIN_VERSION"
helm upgrade --install nvidia-device-plugin \
  oci://nvcr.io/nvidia/k8s-device-plugin \
  --version "v$NVIDIA_PLUGIN_VERSION" \
  --namespace kube-system \
  -f helm/nvidia-device-plugin-values.yaml \
  --wait

log "installing ARC controller $ARC_VERSION"
kubectl create namespace arc-systems --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version "$ARC_VERSION" \
  --namespace arc-systems \
  -f helm/arc-values.yaml \
  --wait

if [[ -z "${GITHUB_PAT:-}" ]]; then
  echo "ERROR: GITHUB_PAT not set — runner scale set requires it. Export and rerun:" >&2
  echo "  export GITHUB_PAT=ghp_xxx" >&2
  echo "  ./bootstrap.sh runners-only" >&2
  exit 2
fi

kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -

log "creating GitHub PAT secret"
kubectl create secret generic github-pat \
  --namespace arc-runners \
  --from-literal=github_token="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

log "installing RunnerScaleSet"
helm upgrade --install lux-gpu-t4 \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version "$ARC_VERSION" \
  --namespace arc-runners \
  -f <(env GITHUB_ORG="$GITHUB_ORG" envsubst < helm/runner-scaleset.yaml) \
  --wait

log "deploy complete. verify:"
echo "  make verify"
