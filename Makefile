.PHONY: help init validate plan apply destroy bootstrap runners verify cost-estimate fmt clean

CLUSTER_NAME ?= lux-gpu-ci
AWS_REGION   ?= us-west-2

help:
	@awk 'BEGIN {FS=":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*##/ {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: ## terraform init
	terraform -chdir=terraform init -upgrade

validate: ## terraform validate
	terraform -chdir=terraform init -backend=false
	terraform -chdir=terraform validate

plan: ## terraform plan
	terraform -chdir=terraform plan -var "region=$(AWS_REGION)" -var "cluster_name=$(CLUSTER_NAME)"

apply: ## terraform apply (creates EKS, ~12-15 minutes)
	terraform -chdir=terraform apply -auto-approve -var "region=$(AWS_REGION)" -var "cluster_name=$(CLUSTER_NAME)"

destroy: ## terraform destroy (tear it all down)
	@echo "DELETING CLUSTER $(CLUSTER_NAME). Ctrl-C in 5s to abort."
	@sleep 5
	terraform -chdir=terraform destroy -auto-approve -var "region=$(AWS_REGION)" -var "cluster_name=$(CLUSTER_NAME)"

bootstrap: ## full one-shot deploy: terraform + helm
	./bootstrap.sh

runners: ## redeploy ARC + RunnerScaleSet only (no terraform)
	./bootstrap.sh runners-only

verify: ## confirm cluster + runner state
	@echo "== nodes =="
	kubectl get nodes -o wide
	@echo
	@echo "== karpenter =="
	kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
	kubectl get nodepools.karpenter.sh
	@echo
	@echo "== nvidia device plugin =="
	kubectl -n kube-system get ds nvidia-device-plugin
	@echo
	@echo "== ARC =="
	kubectl -n arc-systems get pods
	kubectl -n arc-runners get pods
	kubectl -n arc-runners get autoscalingrunnersets

cost-estimate: ## monthly cost estimate
	@echo "Idle:"
	@echo "  EKS control plane:        \$$73/mo  (\$$0.10/hr)"
	@echo "  t3.medium system node:    \$$30/mo  (\$$0.0416/hr on-demand)"
	@echo "  NAT gateway + EIP:        \$$33/mo"
	@echo "  EBS gp3 (20GB system):    \$$2/mo"
	@echo "  ----------------------------------------"
	@echo "  Idle total:               ~\$$138/mo"
	@echo
	@echo "Per GPU build (g4dn.xlarge spot, ~10 min):"
	@echo "  spot price:               ~\$$0.16/hr  →  \$$0.027/build"
	@echo "  EBS scratch:              negligible (deleted on termination)"
	@echo
	@echo "Example: 30 builds/day × \$$0.027 = \$$0.81/day = ~\$$25/mo GPU compute"
	@echo
	@echo "If you only want GPU compute and zero idle, use Lambda Labs / RunPod"
	@echo "instead. EKS+Karpenter is right when you also want DOKS-style"
	@echo "platform features (CRDs, ingress, multiple workloads)."

fmt: ## format terraform
	terraform -chdir=terraform fmt -recursive

clean: ## remove local terraform state cache (does NOT delete cloud resources)
	rm -rf terraform/.terraform terraform/.terraform.lock.hcl
