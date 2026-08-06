# VeloShare — developer workflow shortcuts.
# Thin wrappers around kubectl / helm / kind / docker. Targets are filled in as
# the platform is built out; for now they cover cluster setup and the deploy loop.

CLUSTER   ?= veloshare
NAMESPACE ?= veloshare
RELEASE   ?= veloshare
CHART     ?= ./helm/veloshare
REGISTRY  ?= veloshare
TAG       ?= 0.1.0

# Second tag of ONE service (pricing), built from the same source, so the
# Kustomize overlays can pin genuinely different images per environment:
# k8s/overlays/dev pins $(TAG), k8s/overlays/prod pins $(DEMO_TAG). Built by
# `make images-demo-tag`; not part of `make images` / `make up`.
DEMO_TAG  ?= 0.2.0

SERVICES  := pricing rider station trip fleet-monitor frontend pod-lister

# Per-pod config + credentials. env/<name>.env is local-only and gitignored;
# only env/<name>.env.template is tracked. `make secrets` applies each file to
# the cluster as that pod's Secret — Helm never sees a credential.
ENV_DIR   ?= env
ENV_FILES := postgres rider station trip auth

.PHONY: help cluster-up cluster-down lint template deploy gen-k8s deploy-kubectl uninstall images images-demo-tag load ingress up env-init secrets seed \
	metrics-server history rollback bluegreen-demo bluegreen-clean demo evidence smoke-test

help: ## Show available targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

cluster-up: ## Create the local kind cluster
	kind create cluster --name $(CLUSTER) --config kind-config.yaml

cluster-down: ## Delete the local kind cluster
	kind delete cluster --name $(CLUSTER)

lint: ## Lint the umbrella chart
	helm lint $(CHART)

template: ## Render the umbrella chart locally (no cluster needed)
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE)

deploy: lint ## Install/upgrade the platform onto the cluster
	helm upgrade --install $(RELEASE) $(CHART) -n $(NAMESPACE) --create-namespace

gen-k8s: ## Regenerate k8s/ raw manifests from the Helm chart
	@./scripts/gen-k8s.sh

deploy-kubectl: ## Deploy via raw kubectl/Kustomize instead of Helm (make deploy-kubectl OVERLAY=prod)
	@./scripts/deploy.sh kubectl $(or $(OVERLAY),dev)

uninstall: ## Remove the platform release (asks first in practice)
	helm uninstall $(RELEASE) -n $(NAMESPACE)

history: ## Show Helm release revision history
	helm -n $(NAMESPACE) history $(RELEASE)

rollback: ## Roll back the Helm release to revision REV (make rollback REV=2)
	@if [ -z "$(REV)" ]; then \
		echo "REV is required, e.g.: make rollback REV=2 (see: make history)"; \
		exit 1; \
	fi
	helm -n $(NAMESPACE) rollback $(RELEASE) $(REV)

images: ## Build all app images
	@for svc in $(SERVICES); do \
		docker build -t $(REGISTRY)/$$svc:$(TAG) ./services/$$svc; \
	done

images-demo-tag: ## Build+load a second pricing tag (DEMO_TAG, default 0.2.0) so k8s/overlays/prod pins a different image
	@TAG=$(DEMO_TAG) ./scripts/build.sh pricing
	@echo ""
	@echo "pricing now exists at two tags in cluster '$(CLUSTER)': $(TAG) (dev overlay) and $(DEMO_TAG) (prod overlay)."
	@echo "Prove which one a Pod is running:"
	@echo "  kubectl -n $(NAMESPACE) exec deploy/pricing -c ambassador -- curl -s 127.0.0.1:8080/version"

load: ## Load all app images into the kind cluster
	@for svc in $(SERVICES); do \
		kind load docker-image $(REGISTRY)/$$svc:$(TAG) --name $(CLUSTER); \
	done

env-init: ## Create env/*.env from the templates (does not overwrite existing files)
	@for f in $(ENV_FILES); do \
		if [ -f $(ENV_DIR)/$$f.env ]; then \
			echo "  keep    $(ENV_DIR)/$$f.env (already exists)"; \
		else \
			cp $(ENV_DIR)/$$f.env.template $(ENV_DIR)/$$f.env; \
			chmod 600 $(ENV_DIR)/$$f.env; \
			echo "  created $(ENV_DIR)/$$f.env"; \
		fi; \
	done
	@echo "Now edit $(ENV_DIR)/*.env and replace every change-me value, then run: make secrets"

secrets: ## Apply env/*.env to the cluster as per-pod Secrets (never via Helm/git)
	@NAMESPACE=$(NAMESPACE) ENV_DIR=$(ENV_DIR) ./scripts/apply-secrets.sh

seed: ## Seed demo stations/riders/trips through http://localhost/api/* (safe to re-run)
	@./scripts/seed-data.sh

ingress: ## Install the kind ingress-nginx controller and wait for it
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
	kubectl -n ingress-nginx wait --for=condition=available deploy/ingress-nginx-controller --timeout=180s

metrics-server: ## Install metrics-server, patched for kind (--kubelet-insecure-tls), so the pricing HPA works
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	@if kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-insecure-tls'; then \
		echo "  metrics-server already patched with --kubelet-insecure-tls"; \
	else \
		echo "  patching metrics-server for kind (kubelet serving certs aren't CA-signed)"; \
		kubectl -n kube-system patch deployment metrics-server --type='json' \
			-p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'; \
	fi
	kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s

up: cluster-up ingress secrets images load deploy ## Create cluster, install ingress, apply secrets, build/load images, and deploy

bluegreen-demo: ## Apply the blue/green Service-selector-flip lab (k8s/labs/bluegreen-demo.yaml)
	kubectl apply -n $(NAMESPACE) -f k8s/labs/bluegreen-demo.yaml
	@echo ""
	@echo "Deployed bluegreen-demo-blue + bluegreen-demo-green; Service bluegreen-demo currently -> blue."
	@echo ""
	@echo "Verify which color is serving:"
	@echo "  kubectl -n $(NAMESPACE) get svc bluegreen-demo -o jsonpath='{.spec.selector.color}{\"\\n\"}'"
	@echo "  kubectl -n $(NAMESPACE) run bluegreen-curl --rm -it --restart=Never --image=curlimages/curl -- curl -s bluegreen-demo/"
	@echo ""
	@echo "Flip traffic to green:"
	@echo "  kubectl -n $(NAMESPACE) patch svc bluegreen-demo -p '{\"spec\":{\"selector\":{\"color\":\"green\"}}}'"
	@echo "Flip back to blue:"
	@echo "  kubectl -n $(NAMESPACE) patch svc bluegreen-demo -p '{\"spec\":{\"selector\":{\"color\":\"blue\"}}}'"
	@echo ""
	@echo "Clean up when done: make bluegreen-clean"

bluegreen-clean: ## DESTRUCTIVE: delete the blue/green demo Deployments/ConfigMaps/Service
	@echo "DESTRUCTIVE: deleting bluegreen-demo-blue, bluegreen-demo-green, their ConfigMaps, and the Service."
	kubectl delete -n $(NAMESPACE) -f k8s/labs/bluegreen-demo.yaml

demo: ## Run the guided end-to-end demo script
	@./scripts/demo.sh

evidence: ## Non-interactive demo pass: refresh docs/evidence/*.yaml (read-only, skips destructive steps)
	@AUTO=1 ./scripts/demo.sh

smoke-test: ## Run smoke tests against the deployed platform
	@./scripts/smoke-test.sh
