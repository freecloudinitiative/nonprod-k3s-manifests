.PHONY: lint template schema unittest kyverno-test environment-check validate check-digests

FIND_CHARTS = find infrastructure applications -type f -name Chart.yaml -exec dirname {} \;
HELM_SET = --set image.tag=ci

lint:
	yamllint .
	@for chart in $$($(FIND_CHARTS)); do \
		echo "helm lint $$chart"; \
		helm lint $$chart $(HELM_SET) || exit 1; \
	done

template:
	@for chart in $$($(FIND_CHARTS)); do \
		name=$$(basename $$chart); \
		echo "helm template $$name $$chart"; \
		helm template $$name $$chart $(HELM_SET) >/dev/null || exit 1; \
	done

schema:
	@for chart in $$($(FIND_CHARTS)); do \
		name=$$(basename $$chart); \
		echo "kubeconform $$chart"; \
		helm template $$name $$chart $(HELM_SET) | kubeconform -strict -summary -ignore-missing-schemas || exit 1; \
	done

unittest:
	@test_dirs=$$(find infrastructure applications -type d -name tests 2>/dev/null); \
	if [ -z "$$test_dirs" ]; then \
		echo "No tests found; skipping helm unittest"; \
	else \
		for dir in $$test_dirs; do \
			chart=$$(dirname $$dir); \
			helm unittest $$chart || exit 1; \
		done; \
	fi

kyverno-test:
	@test_dirs=$$(find infrastructure applications -type d -name kyverno-tests 2>/dev/null); \
	if [ -z "$$test_dirs" ]; then \
		echo "No kyverno-tests found; skipping"; \
	else \
		for dir in $$test_dirs; do \
			for run in $$dir/*/run.sh; do \
				echo "$$run"; \
				"$$run" || exit 1; \
			done; \
		done; \
	fi

environment-check:
	@! grep -R -n --include='*.yaml' --include='*.yml' \
		'https://github.com/freecloudinitiative/k3s-manifests.git' infrastructure applications || \
		(echo 'production GitOps repository reference found' && exit 1)
	@! grep -R -n --include='*.yaml' --include='*.yml' \
		'https://freecloudinitiative.com\|https://[^ ]*\.freecloudinitiative.com\|targetRevision: HEAD' \
		infrastructure applications || \
		(echo 'production host or implicit Git revision found' && exit 1)
	@! grep -R -n --include='*.yaml' --include='*.yml' \
		'letsencrypt-production\|type: LoadBalancer\|cloudflared\|metallb' infrastructure applications || \
		(echo 'public-DNS or cloud-load-balancer dependency found' && exit 1)
	@test ! -d infrastructure/cloudflared || \
		(echo 'cloudflared manifests must not exist in nonprod' && exit 1)
	@test ! -d infrastructure/metallb || \
		(echo 'MetalLB manifests must not exist on this AWS cluster' && exit 1)
	@test ! -f infrastructure/namespaces/cloudflared.yaml
	@test ! -f infrastructure/namespaces/metallb-system.yaml
	@echo 'nonprod environment boundary OK'

validate: environment-check lint template schema unittest kyverno-test

check-digests:
	@./scripts/check-image-digests.sh
