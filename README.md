# lux-gpu-ci

Self-hosted GPU CI for Lux EVM CUDA workloads. EKS cluster + Karpenter scales
`g4dn.xlarge` spot instances 0..1 on demand. ARC (Actions Runner Controller)
registers runners with `[self-hosted, linux, amd64, cuda, gpu, t4]` so the
luxcpp/evm CUDA workflow targets it directly.

## Architecture

```
                          ┌─────────────────────────────────────────┐
                          │  GitHub Actions queue (luxcpp/evm)      │
                          │  job: runs-on: [self-hosted,..,cuda,gpu]│
                          └────────────────┬────────────────────────┘
                                           │ webhook / poll
                                           ▼
┌──────────────────────── EKS cluster (us-west-2) ───────────────────────┐
│                                                                         │
│  arc-systems ns          arc-runners ns          kube-system ns         │
│  ┌──────────────┐        ┌──────────────────┐    ┌──────────────────┐   │
│  │ ARC          │ creates│ RunnerScaleSet   │    │ Karpenter ctrl   │   │
│  │ controller   ├───────►│ + ephemeral      │    │ (watches pods)   │   │
│  └──────────────┘        │ runner pods      │    └──────────┬───────┘   │
│                          └────────┬─────────┘               │           │
│                                   │ pod requests            │ unsched.  │
│                                   │ nvidia.com/gpu=1        │ pod →     │
│                                   ▼                         ▼ provision │
│  system node (t3.medium, on-demand, always on)                          │
│  ┌─────────────────────────────────────────┐                            │
│  │ kube-system | arc | karpenter           │                            │
│  └─────────────────────────────────────────┘                            │
│                                                                         │
│  GPU node (g4dn.xlarge, spot, 0..1)  ◄── Karpenter provisions on demand │
│  ┌─────────────────────────────────────────┐                            │
│  │ taint nvidia.com/gpu=present:NoSchedule │                            │
│  │ runs: actions-runner pod (CUDA build)   │                            │
│  │ NVIDIA device plugin DS                 │                            │
│  └─────────────────────────────────────────┘                            │
│  ↑ provisioned on unsched. pod, terminated 30s after pod completes      │
└─────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

| Tool        | Version  | Notes                              |
|-------------|----------|------------------------------------|
| `aws`       | ≥ 2.13   | configured: `aws configure`        |
| `terraform` | ≥ 1.5    | tested with 1.14.5                 |
| `kubectl`   | ≥ 1.30   | client only                        |
| `helm`      | ≥ 3.13   |                                    |
| `envsubst`  | any      | from gettext (`brew install gettext`) |
| AWS account | -        | EKS, EC2 spot, IAM permissions     |
| GitHub PAT  | -        | classic, scopes: `admin:org` + `repo` |

The IAM principal running `terraform apply` needs roughly:
`AmazonEKSClusterPolicy`, `AmazonEC2FullAccess`, `IAMFullAccess`,
`AmazonVPCFullAccess`, plus `sqs:*` and `eks:*`.

## Bootstrap (1 command)

```bash
export AWS_REGION=us-west-2
export GITHUB_ORG=luxfi
export GITHUB_PAT=ghp_xxxx     # admin:org + repo
./bootstrap.sh
```

This runs in two phases (~15 min total):

1. `terraform apply` — VPC, EKS, system node group, Karpenter IAM + SQS (~12 min)
2. Helm — Karpenter, NodePool, NVIDIA device plugin, ARC, RunnerScaleSet (~3 min)

## Verification

```bash
make verify
```

Expected output:

- 1 system node (`t3.medium`)
- Karpenter pod `Running` in `kube-system`
- 1 NodePool: `gpu-spot`
- 0 GPU nodes (spawned on demand)
- ARC controller `Running` in `arc-systems`
- AutoscalingRunnerSet `lux-gpu-t4` in `arc-runners` with 0 active runners

To smoke-test the pipeline:

```bash
gh workflow run cuda.yml --repo luxfi/luxcpp-evm --ref feat/eks-gpu-ci
# Watch:
gh run watch --repo luxfi/luxcpp-evm
# In another terminal:
kubectl get nodes -w   # GPU node appears in ~90s
```

The runner pod will Pending while Karpenter provisions a g4dn.xlarge spot
instance, then move to Running once the node joins the cluster and the NVIDIA
device plugin advertises `nvidia.com/gpu: 1`.

## Tearing down

```bash
make destroy
```

Order matters — terraform destroy will fail if the cluster has
LoadBalancer services (it doesn't here). If GPU nodes are stuck:

```bash
kubectl delete nodepool gpu-spot
kubectl delete nodes -l workload=gpu-ci
make destroy
```

## Cost model

| Component                          | Hourly       | Monthly  |
|------------------------------------|--------------|----------|
| EKS control plane                  | $0.10        | $73      |
| `t3.medium` system node (on-dem)   | $0.0416      | $30      |
| NAT Gateway + EIP + data           | ~$0.045      | ~$33     |
| EBS gp3 system root (20GB)         | -            | $2       |
| **Idle total**                     |              | **~$138/mo** |
| `g4dn.xlarge` spot (active)        | ~$0.16       | $0.027/10-min build |
| `g5.xlarge` spot (fallback)        | ~$0.40       | $0.067/10-min build |

**Monthly cost at typical CI volume** (30 builds/day, 10 min each):

- 30 × 30 × 0.16 / 6 = **$24/mo** GPU compute on top of $138/mo idle
- **Total: ~$162/mo**

If you only need GPU CI (no other K8s workloads), Lambda Labs / RunPod
serverless GPUs are cheaper at this volume. EKS + Karpenter is the right call
when you also want a real K8s platform with CRDs, ingress, multiple
workloads.

## Troubleshooting

### Runner job stuck Queued

Check the RunnerScaleSet picked up the labels:

```bash
kubectl -n arc-runners describe autoscalingrunnerset lux-gpu-t4
kubectl -n arc-runners logs deploy/lux-gpu-t4-listener
```

Job labels (`runs-on`) must match the runner's labels. Defaults advertised:
`self-hosted`, `linux`, `amd64`, `cuda`, `gpu`, `t4`.

### Pod stuck Pending — no nodes

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -20
kubectl -n kube-system logs deploy/karpenter --tail 100
```

Common causes:

- **No spot capacity in region/AZ.** Try a different region or add `g5.xlarge`
  to the EC2NodeClass instance type list (already included as fallback).
- **Subnet/SG discovery tags missing.** Verify `karpenter.sh/discovery=lux-gpu-ci`
  on private subnets and the cluster security group.
- **IAM role can't launch instances.** Check
  `aws iam get-role --role-name lux-gpu-ci-karpenter-node`.

### GPU not detected on the node

```bash
kubectl get nodes -o json | jq '.items[].status.allocatable["nvidia.com/gpu"]'
kubectl -n kube-system logs ds/nvidia-device-plugin
```

If the node has no `nvidia.com/gpu` allocatable resource:

- AL2023 GPU AMI driver may have failed init. SSH via SSM:
  `aws ssm start-session --target i-xxx`, then `nvidia-smi`.
- The device plugin won't tolerate the GPU taint. Verify
  `helm/nvidia-device-plugin-values.yaml` tolerations include
  `nvidia.com/gpu=present:NoSchedule`.

### `terraform apply` fails on Karpenter Pod Identity

The terraform-aws-modules `karpenter` submodule v20 supports both IRSA and Pod
Identity. If you hit "EKS addon eks-pod-identity-agent not found", run:

```bash
aws eks create-addon --cluster-name lux-gpu-ci --addon-name eks-pod-identity-agent
```

then re-run `terraform apply`.

### Cost spike

Check what Karpenter spawned:

```bash
kubectl get nodeclaims.karpenter.sh
aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/cluster,Values=lux-gpu-ci" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime]'
```

NodePool `limits` cap the NodePool at 1 GPU. To temporarily disable spawning:

```bash
kubectl patch nodepool gpu-spot --type merge -p '{"spec":{"limits":{"nvidia.com/gpu":"0"}}}'
```

## Layout

```
.
├── Makefile                              # init/apply/destroy/verify/cost-estimate
├── README.md                             # this file
├── bootstrap.sh                          # one-shot deploy
├── terraform/
│   ├── versions.tf                       # provider pins
│   ├── variables.tf
│   └── main.tf                           # VPC, EKS, system NG, Karpenter IAM
└── helm/
    ├── karpenter-values.yaml             # controller chart values
    ├── karpenter-nodepool.yaml           # NodePool + EC2NodeClass v1 spec
    ├── nvidia-device-plugin-values.yaml  # device plugin DS values
    ├── arc-values.yaml                   # ARC controller values
    └── runner-scaleset.yaml              # RunnerScaleSet values (Helm chart)
```
