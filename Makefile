# Summit Peak observability lab. Run `make help` to see every command.
SHELL := /bin/bash
CLUSTER := summit-peak
APPS := -n summit-peak
OBS := -n observability
-include .env
export

# Call an HTTP endpoint from inside the cluster (the load generator pod has Python and httpx).
define incluster
kubectl $(APPS) exec deploy/loadgen -- python -c "import httpx,sys; r=httpx.post('$(1)', json=$(2), timeout=10); print(r.text)"
endef

.PHONY: help
help: ## Show this list
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- lab lifecycle
.PHONY: up
up: cluster build deploy ## Create the cluster, build the images and deploy everything
	@echo ""
	@echo "Lab is up. Next: 'make status', then 'make jaeger' to open traces."

.PHONY: cluster
cluster: ## Create the local Kubernetes cluster (kind)
	@kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config k8s/kind.yaml

.PHONY: build
build: ## Build the app and loader images and load them into the cluster
	docker build -t summit-peak/app:lab services
	docker build -t summit-peak/loader:lab loader
	kind load docker-image summit-peak/app:lab summit-peak/loader:lab --name $(CLUSTER)

.PHONY: deploy
deploy: ## Apply the Kubernetes manifests and the Collector config
	kubectl apply -f k8s/observability.yaml
	kubectl $(OBS) create configmap otel-collector-config --from-file=collector/collector.yaml \
	  --dry-run=client -o yaml | kubectl apply -f -
	@HASH=$$(sha1sum collector/collector.yaml | cut -c1-12); \
	  kubectl $(OBS) patch deployment otel-collector -p \
	  "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config-hash\":\"$$HASH\"}}}}}" >/dev/null
	kubectl apply -f k8s/apps.yaml
	kubectl $(APPS) rollout restart deployment >/dev/null
	kubectl $(OBS) rollout status deployment/otel-collector --timeout=180s
	kubectl $(APPS) rollout status deployment/payments --timeout=180s

.PHONY: status
status: ## Show pods, current traffic and what the loader has sent to Snowflake
	@kubectl get pods -A -l 'app in (lift-tickets,rentals,payments,notifications,loadgen,otel-collector,snowflake-loader,jaeger)'
	@echo ""; echo "Traffic in the last 30 seconds (HTTP status: count):"
	@kubectl $(APPS) exec deploy/loadgen -- python -c "import httpx; print(httpx.get('http://localhost:8000/rate').text)"
	@echo ""; echo "Snowflake loader:"
	@kubectl $(OBS) exec deploy/snowflake-loader -- python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:4318/healthz').read().decode())"

.PHONY: jaeger
jaeger: ## Open the Jaeger UI on port 16686 (Codespaces forwards it automatically)
	kubectl $(OBS) port-forward svc/jaeger 16686:16686

.PHONY: down
down: ## Delete the cluster (Snowflake data is kept)
	kind delete cluster --name $(CLUSTER)

# ---------------------------------------------------------------- Snowflake
.PHONY: keys
keys: ## Generate the loader's key pair and print the SQL to register it
	@mkdir -p .secrets
	@test -f .secrets/loader_key.p8 || openssl genrsa 2048 2>/dev/null | openssl pkcs8 -topk8 -inform PEM -out .secrets/loader_key.p8 -nocrypt
	@openssl rsa -in .secrets/loader_key.p8 -pubout 2>/dev/null > .secrets/loader_key.pub
	@echo "Run this in Snowflake as ACCOUNTADMIN:"
	@echo ""
	@echo "ALTER USER OBS_LOADER_SVC SET RSA_PUBLIC_KEY = '$$(grep -v -- '-----' .secrets/loader_key.pub | tr -d '\n')';"

.PHONY: snowflake-secret
snowflake-secret: ## Give the loader its Snowflake account and key (reads SNOWFLAKE_ACCOUNT from .env)
	@test -n "$(SNOWFLAKE_ACCOUNT)" || (echo "Add SNOWFLAKE_ACCOUNT=<orgname-accountname> to .env first"; exit 1)
	@test -f .secrets/loader_key.p8 || (echo "Run 'make keys' first"; exit 1)
	kubectl $(OBS) create secret generic snowflake-loader \
	  --from-literal=SNOWFLAKE_ACCOUNT=$(SNOWFLAKE_ACCOUNT) \
	  --from-file=loader_key.p8=.secrets/loader_key.p8 \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl $(OBS) rollout restart deployment/snowflake-loader
	kubectl $(OBS) rollout status deployment/snowflake-loader --timeout=120s

# ---------------------------------------------------------------- scenarios
.PHONY: powder-day
powder-day: ## Fresh snow: traffic jumps to 30 requests per second
	@$(call incluster,http://localhost:8000/rate,{'rps': 30})

.PHONY: provider-slow
provider-slow: ## The payment provider slows down to ~600 ms per charge
	@$(call incluster,http://payments:8000/admin/provider,{'latency_ms': 600})

.PHONY: incident
incident: powder-day provider-slow ## Both at once: the powder-day incident
	@echo "Incident started. The SLO alert should open an incident within a few minutes."

.PHONY: recover
recover: ## The provider recovers (traffic stays high)
	@$(call incluster,http://payments:8000/admin/provider,{'latency_ms': 120})

.PHONY: calm
calm: recover ## Back to a quiet day: normal provider, 4 requests per second
	@$(call incluster,http://localhost:8000/rate,{'rps': 4})

# ---------------------------------------------------------------- debugging
.PHONY: logs-collector
logs-collector: ## Follow the Collector's own logs
	kubectl $(OBS) logs -f deploy/otel-collector

.PHONY: logs-loader
logs-loader: ## Follow the Snowflake loader's logs
	kubectl $(OBS) logs -f deploy/snowflake-loader

.PHONY: validate
validate: ## Check the Collector config without deploying it
	docker run --rm -v $$PWD/collector:/conf otel/opentelemetry-collector-contrib:0.135.0 validate --config=/conf/collector.yaml
