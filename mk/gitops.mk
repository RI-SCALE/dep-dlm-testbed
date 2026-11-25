# GitOps: Argo CD and Flux.
# Included from the Makefile after mk/config.mk.

GITOPS_REVISION ?= main
GITOPS_REPO_URL ?=
ARGOCD_NAMESPACE ?= argocd
FLUX_NAMESPACE ?= flux-system

## GitOps

.PHONY: argocd-install
argocd-install: ## Install ArgoCD, bootstrap GITOPS_ENV
	@OIDC_CLIENT_ID='$(OIDC_CLIENT_ID)' OIDC_CLIENT_SECRET='$(OIDC_CLIENT_SECRET)' \
	./scripts/init-argocd.sh --env $(GITOPS_ENV) \
	    --flow $(TOKEN_MODE) --scope-profile $(SCOPE_PROFILE) \
	    $(if $(GITOPS_REPO_URL),--repo-url $(GITOPS_REPO_URL)) \
	    $(if $(GITOPS_REVISION),--revision $(GITOPS_REVISION))

.PHONY: argocd-uninstall
argocd-uninstall: ## Remove ArgoCD apps and resources
	# 1. Delete the app-of-apps roots first (stops selfHeal recreating).
	kubectl -n $(ARGOCD_NAMESPACE) delete application dep-dlm-$(GITOPS_ENV)-apps dep-dlm-$(GITOPS_ENV)-secrets --ignore-not-found --wait=false
	# 2. Delete component apps but KEEP external-secrets so it can clear finalizers.
	kubectl -n $(ARGOCD_NAMESPACE) delete applications -l '!keep' --field-selector metadata.name!=external-secrets --ignore-not-found --wait=false || \
	  kubectl -n $(ARGOCD_NAMESPACE) delete application vault ruciodb rucio-server rucio-daemons rucio-bootstrap keycloak xrootd teapot fts --ignore-not-found --wait=false
	# 3. Clear ESO-managed resources while ESO is still alive.
	-kubectl delete clustersecretstore dep-dlm-secrets --ignore-not-found
	-for es in $$(kubectl get externalsecret -n $(K8S_NAMESPACE) -o name 2>/dev/null); do \
	  kubectl delete -n $(K8S_NAMESPACE) $$es --ignore-not-found; done
	# 4. Now the namespace can finalize. NOTE: vault-seed-once and
	#    rucio-bootstrap-db are imperative Jobs (scripts/seed-vault.sh,
	#    run-bootstrap-db.sh) — not GitOps-managed, so nothing above prunes
	#    them, but they live in this namespace and are deleted with it here.
	kubectl delete namespace $(K8S_NAMESPACE) --ignore-not-found --timeout=360s
	# 5. Finally remove ESO and Argo.
	kubectl -n $(ARGOCD_NAMESPACE) delete application external-secrets --ignore-not-found
	kubectl delete namespace $(ARGOCD_NAMESPACE) --ignore-not-found
	@echo "GitOps $(GITOPS_ENV) and Argo CD removed"

.PHONY: argocd-open
argocd-open: ## Open the Argo CD UI (port-forwards argocd-server until Ctrl-C; user: admin)
	@trap 'kill $$(jobs -p) 2>/dev/null' EXIT; \
	kubectl -n $(ARGOCD_NAMESPACE) port-forward svc/argocd-server 8080:443 >/dev/null & \
	sleep 2; \
	echo "Argo CD https://localhost:8080  user: admin  password: $$(kubectl -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"; \
	$(OPEN_URL) https://localhost:8080; \
	echo "(Ctrl-C to stop)"; \
	wait

.PHONY: flux-install
flux-install: ## Install Flux, bootstrap GITOPS_ENV
	@OIDC_CLIENT_ID='$(OIDC_CLIENT_ID)' OIDC_CLIENT_SECRET='$(OIDC_CLIENT_SECRET)' \
	./scripts/init-flux.sh --env $(GITOPS_ENV) \
	    --flow $(TOKEN_MODE) --scope-profile $(SCOPE_PROFILE) \
	    $(if $(GITOPS_REPO_URL),--repo-url $(GITOPS_REPO_URL)) \
	    $(if $(GITOPS_REVISION),--revision $(GITOPS_REVISION))

.PHONY: flux-uninstall
flux-uninstall: ## Remove Flux Kustomizations and controllers
	# 1. Suspend + delete the entrypoint Kustomizations (stops Flux re-reconciling). Reverse order: components -> secrets -> eso.
	kubectl -n $(FLUX_NAMESPACE) delete kustomization dep-dlm-$(GITOPS_ENV) --ignore-not-found --wait=false
	kubectl -n $(FLUX_NAMESPACE) delete kustomization dep-dlm-$(GITOPS_ENV)-secrets --ignore-not-found --wait=false
	# 2. Clear ESO-managed resources WHILE ESO is still alive (avoids finalizer deadlock).
	-kubectl delete clustersecretstore dep-dlm-secrets --ignore-not-found
	-for es in $$(kubectl get externalsecret -n $(K8S_NAMESPACE) -o name 2>/dev/null); do \
	  kubectl delete -n $(K8S_NAMESPACE) $$es --ignore-not-found; done
	# 3. Now the workload namespace can finalize
	kubectl delete namespace $(K8S_NAMESPACE) --ignore-not-found --timeout=360s
	# 4. Remove ESO (its own Kustomization) and the HelmReleases it managed.
	kubectl -n $(FLUX_NAMESPACE) delete kustomization dep-dlm-$(GITOPS_ENV)-eso --ignore-not-found --wait=false
	# 5. Remove both GitRepository sources
	kubectl -n $(FLUX_NAMESPACE) delete gitrepository dep-dlm-testbed rucio-charts-fork --ignore-not-found
	# 5b. Belt-and-braces
	-kubectl -n $(FLUX_NAMESPACE) delete helmrelease,helmchart,kustomization,gitrepository --all --ignore-not-found --wait=true --timeout=60s
	-for r in $$(kubectl -n $(FLUX_NAMESPACE) get helmrelease,helmchart,kustomization,gitrepository -o name 2>/dev/null); do \
	  kubectl -n $(FLUX_NAMESPACE) patch $$r --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true; done
	@echo "GitOps $(GITOPS_ENV) Flux Kustomizations removed (Flux controllers left intact)"
	# 6. Uinstall Flux itself
	flux uninstall --namespace=$(FLUX_NAMESPACE) --silent 2>/dev/null || \
	  kubectl delete namespace $(FLUX_NAMESPACE) --ignore-not-found
	@echo "Flux controllers removed"
	# 7. Belt-and-braces for the namespace itself
	-kubectl get namespace $(FLUX_NAMESPACE) >/dev/null 2>&1 && \
	  kubectl get namespace $(FLUX_NAMESPACE) -o json 2>/dev/null \
	  | python3 -c "import json,sys; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" \
	  | kubectl replace --raw "/api/v1/namespaces/$(FLUX_NAMESPACE)/finalize" -f - >/dev/null 2>&1 || true
