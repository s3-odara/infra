.DEFAULT_GOAL := help

.PHONY: help plan deploy tofu-apply guests host-update secrets install-host update-flake

help:
	@printf '%s\n' \
	  'make plan' \
	  'make deploy' \
	  'make tofu-apply' \
	  'make guests [GUESTS="prosody wireguard"]' \
	  'make host-update' \
	  'make secrets ARGS="--target me@HOST init prosody"' \
	  'make install-host CONFIG=incus-01 TARGET=root@HOST' \
	  'make update-flake'

plan:
	./scripts/tofu.sh plan

deploy:
	./scripts/tofu.sh apply
	./scripts/guests.sh

tofu-apply:
	./scripts/tofu.sh apply

guests:
	./scripts/guests.sh $(GUESTS)

host-update:
	doas systemctl start --wait nixos-upgrade.service

secrets:
	./scripts/secrets.sh $(ARGS)

install-host:
	@test -n "$(CONFIG)" && test -n "$(TARGET)" || \
	  { echo 'CONFIG and TARGET are required' >&2; exit 1; }
	./scripts/install-host.sh "$(CONFIG)" "$(TARGET)"

update-flake:
	./scripts/update-flake.sh
