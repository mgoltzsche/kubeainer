KUBE_IMAGE ?= local/kubernetes
#KUBE_MASTER ?= `ip -4 route get 8.8.8.8 | awk {'print $$7'} | tr -d '\n'`:6443
#KUBE_MASTER ?= 10.254.0.2:6443
KUBE_NET ?= 10.23.0.0/16
KUBE_MASTER_IP ?= 10.23.0.2
# Use original resolv.conf (uncached)
RESOLV_CONF ?= $(word 1, $(wildcard /etc/resolvconf/resolv.conf.d/original /run/systemd/resolve/resolv.conf /etc/resolv.conf))
CA_CN ?= example.org

all: build ca-cert net-create run-master run-node

build:
	docker build -f Dockerfile-centos -t ${KUBE_IMAGE} .

build-alpine:
	docker build -f Dockerfile-alpine -t ${KUBE_IMAGE} .

ca-cert:
	./ca.sh initca ${CA_CN}

net-create:
	docker network create --subnet=${KUBE_NET} kubeclusternet

net-remove:
	docker network rm kubeclusternet

run-master:
	# Start a kubernetes node
	# Note: Use oci systemd hooks, see https://developers.redhat.com/blog/2016/09/13/running-systemd-in-a-non-privileged-container/
	# HINT: swap must be disabled: swapoff -a
	$(eval KUBE_TOKEN ?= $(shell docker run --entrypoint=/opt/bin/kubeadm ${KUBE_IMAGE} token generate))
	$(if $(strip $(KUBE_TOKEN)),,$(error KUBE_TOKEN not set and cannot not be derived))
	docker run -d --name kube-master --privileged --net=kubeclusternet --ip ${KUBE_MASTER_IP} \
		-v /sys/fs/cgroup:/sys/fs/cgroup:rw \
		-v /lib/modules:/lib/modules:ro \
		-v /boot:/boot:ro \
		-v /etc/machine-id:/etc/machine-id:ro \
		-v ${RESOLV_CONF}:/etc/resolv.conf \
		-v `pwd`/ca-cert/ca.key:/etc/kubernetes/pki/ca.key:ro \
		-v `pwd`/ca-cert/ca.crt:/etc/kubernetes/pki/ca.crt:ro \
		-v `pwd`/conf/manifests/admin-service-account.yaml:/etc/kubernetes/manifests/admin-service-account.yaml:ro \
		-v $$HOME/.kube:/root/.kube \
		--tmpfs /run \
		--tmpfs /tmp \
		-e KUBE_TYPE=master \
		-e KUBE_TOKEN="${KUBE_TOKEN}" \
		${KUBE_IMAGE}
#-v `pwd`/conf/manifests/admin-service-account.yaml:/etc/kubernetes/admin-service-account.yaml:ro \

run-node:
	$(if $(strip $(KUBE_MASTER_IP)),,$(error KUBE_MASTER_IP not set))
	$(if $(strip $(KUBE_TOKEN)),,$(error KUBE_TOKEN not set))
	$(eval KUBE_CA_CERT_HASH ?= sha256:$(shell openssl x509 -in ca-cert/ca.crt -noout -pubkey | openssl rsa -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1))
	$(if $(strip $(KUBE_CA_CERT_HASH)),,$(error KUBE_CA_CERT_HASH not set and cannot be derived))
	docker run -d --name kube-node --privileged --net=kubeclusternet --link kube-master \
		-v /sys/fs/cgroup:/sys/fs/cgroup:rw \
		-v /lib/modules:/lib/modules:ro \
		-v /boot:/boot:ro \
		-v ${RESOLV_CONF}:/etc/resolv.conf \
		-v $$HOME/.kube:/root/.kube \
		--tmpfs /run \
		--tmpfs /tmp \
		-e KUBE_TYPE=node \
		-e KUBE_MASTER="${KUBE_MASTER_IP}:6443" \
		-e KUBE_TOKEN="${KUBE_TOKEN}" \
		-e KUBE_CA_CERT_HASH="${KUBE_CA_CERT_HASH}" \
		${KUBE_IMAGE}
# -v /sys/fs/cgroup/systemd:/sys/fs/cgroup/systemd:rw \

clean:
	make stop-node; \
	make stop-master; \
	make net-remove

stop-node:
	docker stop kube-node
	docker rm kube-node

stop-master:
	docker stop kube-master
	docker rm kube-master

cfssl:
	docker run -ti -v `pwd`/ssl:/etc/ssl cfssl/cfssl

install-kubectl:
	curl -L https://storage.googleapis.com/kubernetes-release/release/v1.13.2/bin/linux/amd64/kubectl > /usr/local/bin/kubectl
	chmod 754 /usr/local/bin/kubectl
	chown root:docker /usr/local/bin/kubectl

proxy:
	# Browse http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/
	kubectl proxy

dashboard-token:
	kubectl -n kube-system describe secret `kubectl -n kube-system get secret | grep kubernetes-dashboard-token | awk '{print $$1}'`

admin-token:
	kubectl -n kube-system describe secret `kubectl -n kube-system get secret | grep admin-user-token | awk '{print $$1}'`

#-v /run:/run
#-v /etc/systemd:/etc/systemd
