IMAGE ?= pi-keepalived:test
SHELLCHECK_IMAGE ?= koalaman/shellcheck:v0.10.0
TRIVY_IMAGE ?= aquasec/trivy:0.67.2

.PHONY: build test lint scan verify

build:
	docker build --pull --tag $(IMAGE) .

test: build
	IMAGE=$(IMAGE) bash tests/run.sh

lint:
	docker run --rm --volume "$(CURDIR):/mnt:ro" --workdir /mnt \
		$(SHELLCHECK_IMAGE) entrypoint.sh check-dns.sh tests/run.sh

scan:
	docker build --pull --no-cache --tag $(IMAGE) .
	docker run --rm --volume /var/run/docker.sock:/var/run/docker.sock \
		$(TRIVY_IMAGE) image --exit-code 1 --ignore-unfixed \
		--severity HIGH,CRITICAL --scanners vuln --skip-version-check $(IMAGE)

verify: lint test scan