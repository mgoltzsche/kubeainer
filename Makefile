# Note: Use oci systemd hooks to integrate the container's systemd into the host's,
#       see https://developers.redhat.com/blog/2016/09/13/running-systemd-in-a-non-privileged-container/

VERSION ?= $(shell cat VERSION)
KUBE_IMAGE_NAME = mgoltzsche/kubeainer
KUBE_IMAGE ?= $(KUBE_IMAGE_NAME):$(VERSION)
KUBE_IMAGE_PRELOADED ?= $(KUBE_IMAGE)-preloaded
KUBE_NET ?= 10.23.0.0/16
DOCKER ?= docker
DOCKER_COMPOSE ?= docker-compose

BUILD_DIR := $(shell pwd)/build
BIN_DIR := $(BUILD_DIR)/bin
BATS_DIR = $(BUILD_DIR)/tools/bats
BATS = $(BIN_DIR)/bats
BATS_VERSION = v1.3.0
KPT = $(BIN_DIR)/kpt
KPT_VERSION = v0.39.2

PRELOADED_IMAGES_DIR=preloaded-images

all: apps image

image:
	$(DOCKER) build --force-rm -t $(KUBE_IMAGE) --target=k8s .

test: image $(BATS)
	timeout 1200s $(BATS) -T ./test

apps: $(KPT)
	$(KPT) fn run --network --mount "type=bind,src=`pwd`/conf/apps,target=/apps" --as-current-user conf/apps

image-preloaded: image $(PRELOADED_IMAGES_DIR)/empty-store
	$(eval K8S_VERSION = $(shell $(DOCKER) run --rm --privileged --entrypoint=/bin/sh $(KUBE_IMAGE) -c 'echo $$K8S_VERSION'))
	[ -d "$(PRELOADED_IMAGES_DIR)/$(K8S_VERSION)" ] || \
	(mkdir -p $(PRELOADED_IMAGES_DIR)/$(K8S_VERSION).tmp && \
	$(DOCKER) run --rm --privileged \
		--mount type=bind,source=`pwd`/$(PRELOADED_IMAGES_DIR)/$(K8S_VERSION).tmp,target=/data \
		--mount type=bind,source=`pwd`/preload-images.sh,target=/preload-images.sh \
		--entrypoint=/preload-images.sh \
		$(KUBE_IMAGE) && \
	mv $(PRELOADED_IMAGES_DIR)/$(K8S_VERSION).tmp $(PRELOADED_IMAGES_DIR)/$(K8S_VERSION))
	ln -sf $(K8S_VERSION) $(PRELOADED_IMAGES_DIR)/current
	$(DOCKER) build --force-rm -t $(KUBE_IMAGE_PRELOADED) .

$(PRELOADED_IMAGES_DIR)/empty-store: image
	mkdir -p $(PRELOADED_IMAGES_DIR)/empty-store.tmp
	$(DOCKER) run --rm --privileged \
		--mount type=bind,source=`pwd`/$(PRELOADED_IMAGES_DIR)/empty-store.tmp,target=/data \
		--entrypoint=/bin/sh \
		$(KUBE_IMAGE) \
		-c 'crio --root=/data & CRIO_PID=$$!; sleep 3; kill $$CRIO_PID; sleep 3; ! kill -0 $$CRIO_PID 2>/dev/null; \
		find /data -type d | xargs chmod +rx; \
		find /data -type f | xargs chmod +r'
	mv $(PRELOADED_IMAGES_DIR)/empty-store.tmp $(PRELOADED_IMAGES_DIR)/empty-store

docker-push:
	docker push ${KUBE_IMAGE}
	docker tag ${KUBE_IMAGE} ${KUBE_IMAGE_NAME}:latest
	docker push ${KUBE_IMAGE_NAME}:latest

release: update-release-version apps image test docker-push

update-release-version: KUBE_IMAGE_NAME_ESCAPED=$(subst /,\/,$(KUBE_IMAGE_NAME))
update-release-version:
	@! test "$(VERSION)" = `cat VERSION` || (echo no new release VERSION specified >&2; false)
	sed -Ei 's/ $(KUBE_IMAGE_NAME_ESCAPED):.+$$/ $(KUBE_IMAGE_NAME_ESCAPED):$(VERSION)/g' docker-compose.yaml
	echo "$(VERSION)" > VERSION

check-repo-unchanged:
	@[ -z "`git status --untracked-files=no --porcelain`" ] || (\
		echo 'ERROR: the build changed files tracked by git:'; \
		git status --untracked-files=no --porcelain | sed -E 's/^/  /'; \
		echo 'Please call `make apps` and commit the resulting changes.'; \
		false) >&2

compose-up: NODES?=0
compose-up:
	$(DOCKER_COMPOSE) up -d --scale kube-node=$(NODES)
	$(DOCKER_COMPOSE) exec -T kube-master kubeainer install

compose-down:
	$(DOCKER_COMPOSE) down -v --remove-orphans

compose-stop:
	$(DOCKER_COMPOSE) stop

compose-rm:
	$(DOCKER_COMPOSE) rm -sf

compose-sh:
	$(DOCKER) exec -it `basename '$(CURDIR)'`_kube-master_1 /bin/bash

net-create:
	$(DOCKER) network create --subnet=$(KUBE_NET) kubeclusternet

net-remove:
	$(DOCKER) network rm kubeclusternet || true

start-master: image net-create
	# Start a kubernetes node
	# HINT: swap should be disabled: swapoff -a
	# HINT: The following mounts may be needed when working with ceph or kata:
	#   -v /lib/modules:/lib/modules:ro
	#   -v /boot:/boot:ro
	#   -v /sys/fs/cgroup:/sys/fs/cgroup:rw
	mkdir -p -m 0755 crio-data1 crio-data2
	$(DOCKER) run -d --name kube-master --rm --privileged \
		--net=kubeclusternet --hostname kube-master \
		--mount type=bind,source=`pwd`/crio-data1,target=/data,bind-propagation=rshared \
		-v `pwd`:/output:rw \
		-e KUBE_TYPE=master \
		$(KUBE_IMAGE)
	$(DOCKER) exec kube-master kubeainer install metallb local-path-provisioner

start-node:
	$(DOCKER) run -d --name kube-node --hostname kube-node --rm --privileged \
		--net=kubeclusternet --link kube-master \
		--mount type=bind,source=`pwd`/crio-data2,target=/data,bind-propagation=rshared \
		-e KUBE_TYPE=node \
		$(KUBE_IMAGE)

stop-node:
	$(DOCKER) stop kube-node || true
	$(DOCKER) rm kube-node || true

stop-master:
	$(DOCKER) stop kube-master || true
	$(DOCKER) rm kube-master || true

clean: stop-node stop-master net-remove
	# TODO: avoid this by properly deleting all pods before terminating the parent pod
	mount | grep -Eo " `pwd`/crio-data[0-9]+/[^ ]+" | xargs umount || true
	docker run -ti --rm --mount type=bind,src=`pwd`,target=/work -w /work alpine:3.13 rm -rf preloaded-images

clean-storage: clean
	mount | grep -Eo " `pwd`/crio-data[0-9]+/[^ ]+" | xargs umount || true
	rm -rf crio-data*

install-kubectl: K8S_VERSION?=v1.21.1
install-kubectl:
	curl -fsSL https://storage.googleapis.com/kubernetes-release/release/$(K8S_VERSION)/bin/linux/amd64/kubectl > /usr/local/bin/kubectl
	chmod +x /usr/local/bin/kubectl

proxy:
	# Browse http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/
	kubectl proxy

dashboard-token:
	kubectl -n kube-system describe secret `kubectl -n kube-system get secret | grep kubernetes-dashboard-token | awk '{print $$1}'`

admin-token:
	kubectl -n kube-system describe secret `kubectl -n kube-system get secret | grep admin-user-token | awk '{print $$1}'`

$(KPT): kpt
kpt:
	$(call download-bin,$(KPT),"https://github.com/GoogleContainerTools/kpt/releases/download/$(KPT_VERSION)/kpt_$$(uname | tr '[:upper:]' '[:lower:]')_amd64")

$(BATS):
	@echo Downloading bats
	@{ \
	set -e ;\
	mkdir -p $(BIN_DIR) ;\
	TMP_DIR=$$(mktemp -d) ;\
	cd $$TMP_DIR ;\
	git clone -c 'advice.detachedHead=false' --branch $(BATS_VERSION) https://github.com/bats-core/bats-core.git . >/dev/null;\
	./install.sh $(BATS_DIR) ;\
	ln -s $(BATS_DIR)/bin/bats $(BATS) ;\
	}

# download-bin downloads a binary into the location given as first argument
define download-bin
@[ -f $(1) ] || { \
set -e ;\
mkdir -p `dirname $(1)` ;\
TMP_FILE=$$(mktemp) ;\
echo "Downloading $(2)" ;\
curl -fsSLo $$TMP_FILE $(2) ;\
chmod +x $$TMP_FILE ;\
mv $$TMP_FILE $(1) ;\
}
endef
