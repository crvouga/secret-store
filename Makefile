.PHONY: gh

gh:
	open "https://github.com/crvouga/secret-store/actions"

sync-dev-keys-to-prd:
	./scripts/sync-dev-keys-to-prd.sh

seed-vault-token:
	./scripts/seed-vault-token.sh