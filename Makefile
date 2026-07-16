# VeloShare — developer workflow shortcuts.
# Thin wrappers around kubectl / helm / kind / docker. Targets are filled in as
# the platform is built out; for now they cover cluster setup and the deploy loop.

CLUSTER   ?= veloshare
NAMESPACE ?= veloshare
RELEASE   ?= veloshare
CHART     ?= ./helm/veloshare
REGISTRY  ?= veloshare
TAG       ?= 0.1.0

SERVICES  := pricing rider station trip fleet-monitor frontend

# Per-pod config + credentials. env/<name>.env is local-only and gitignored;
# only env/<name>.env.template is tracked. `make secrets` applies each file to
# the cluster as that pod's Secret — Helm never sees a credential.
ENV_DIR   ?= env
ENV_FILES := postgres rider station trip auth

.PHONY: help cluster-up cluster-down lint template deploy uninstall images load ingress up env-init secrets

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

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

uninstall: ## Remove the platform release (asks first in practice)
	helm uninstall $(RELEASE) -n $(NAMESPACE)

images: ## Build all app images
	@for svc in $(SERVICES); do \
		docker build -t $(REGISTRY)/$$svc:$(TAG) ./$$svc; \
	done

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
	@missing=0; for f in $(ENV_FILES); do \
		[ -f $(ENV_DIR)/$$f.env ] || { echo "missing $(ENV_DIR)/$$f.env"; missing=1; }; \
	done; \
	if [ $$missing -ne 0 ]; then \
		echo "-> run 'make env-init' to create them from the templates, then edit the values"; \
		exit 1; \
	fi
	@if grep -rlqE '^[A-Za-z_][A-Za-z0-9_]*=change-me' $(ENV_DIR)/*.env 2>/dev/null; then \
		echo "refusing: these $(ENV_DIR)/*.env values are still template placeholders:"; \
		grep -rnE '^[A-Za-z_][A-Za-z0-9_]*=change-me' $(ENV_DIR)/*.env | sed 's/^/    /'; \
		exit 1; \
	fi
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f - >/dev/null
	@set -e; \
	 apply() { kubectl -n $(NAMESPACE) create secret generic $$1 --from-env-file=$$2 \
	     --dry-run=client -o yaml | kubectl apply -f - >/dev/null; echo "  secret/$$1 <- $$2"; }; \
	 apply postgres       $(ENV_DIR)/postgres.env; \
	 apply rider-db       $(ENV_DIR)/rider.env; \
	 apply station-db     $(ENV_DIR)/station.env; \
	 apply trip-db        $(ENV_DIR)/trip.env; \
	 apply veloshare-auth $(ENV_DIR)/auth.env

ingress: ## Install the kind ingress-nginx controller and wait for it
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
	kubectl -n ingress-nginx wait --for=condition=available deploy/ingress-nginx-controller --timeout=180s

up: cluster-up ingress secrets images load deploy ## Create cluster, install ingress, apply secrets, build/load images, and deploy
