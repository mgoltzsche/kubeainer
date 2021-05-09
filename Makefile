# Note: Use oci systemd hooks to integrate the container's systemd into the host's,
#       see https://developers.redhat.com/blog/2016/09/13/running-systemd-in-a-non-privileged-container/

KUBE_IMAGE ?= local/kubernetes:latest
KUBE_IMAGE_PRELOADED ?= $(KUBE_IMAGE)-preloaded
KUBE_NET ?= 10.23.0.0/16
DOCKER ?= docker
DOCKER_COMPOSE ?= docker-compose

image:
	$(DOCKER) build --force-rm -t $(KUBE_IMAGE) .

image-preloaded: CONTAINER_NAME=kube-image-preload
# TODO: make sure there are no container mounts left when terminating the node previously. otherwise cp fails
image-preloaded: image
	STATUS=0; \
	( \
		$(DOCKER) run --name $(CONTAINER_NAME) --privileged \
			-e KUBE_IMAGES_PRELOADED=true \
			--mount type=bind,source=`pwd`/crio-data1,target=/data \
			$(KUBE_IMAGE) && \
		$(DOCKER) commit $(CONTAINER_NAME) $(KUBE_IMAGE_PRELOADED) \
	) || STATUS=$$? \
	$(DOCKER) rm $(CONTAINER_NAME) \
	exit $$STATUS

compose-up: image
	$(DOCKER_COMPOSE) up -d
	$(DOCKER_COMPOSE) exec kube-master kubeainer install metallb local-path-provisioner

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

clean-storage: clean
	mount | grep -Eo " `pwd`/crio-data[0-9]+/[^ ]+" | xargs umount || true
	rm -rf crio-data*

install-kubectl: K8S_VERSION?=v1.20.5
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
