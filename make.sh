#!/bin/sh

set -e
	: ${KUBE_IMAGE:=local/kubernetes}
	: ${KUBE_NET:=10.23.0.0/16}
	#: ${KUBE_MASTER_IP:=10.23.0.2}
	: ${KUBE_MASTER_IP:=`ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n'`}
	# Use original resolv.conf (uncached)
	: ${RESOLV_CONF:=$(find /etc/resolvconf/resolv.conf.d/original /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null | head -1)}
	: ${CA_CN:=example.org}

IMAGES='k8s.gcr.io/kube-apiserver:v1.13.2
		k8s.gcr.io/kube-proxy:v1.13.2
		k8s.gcr.io/kube-controller-manager:v1.13.2
		k8s.gcr.io/kube-scheduler:v1.13.2
		k8s.gcr.io/kubernetes-dashboard-amd64:v1.10.1
		k8s.gcr.io/coredns:1.2.6
		k8s.gcr.io/etcd:3.2.24
		k8s.gcr.io/pause:3.1
		weaveworks/weave-npc:2.5.1
		weaveworks/weave-kube:2.5.1'

build() {
	loadImages &&
	docker build --force-rm -f Dockerfile-centos -t ${KUBE_IMAGE} .
}

loadImages() {
	[ -f preloaded-images.tar ] ||
	(echo ${IMAGES} | xargs -n1 docker image pull &&
	docker save ${IMAGES} > preloaded-images.tar)
}

initCA() {
	[ -f ca-cert/ca.key ] || ./ca.sh initca ${CA_CN}
}

netCreate() {
	docker network create --subnet=${KUBE_NET} kubeclusternet
}

netRemove() {
	docker network rm kubeclusternet
}

startMaster() {
	# Start a kubernetes node
	# Note: Use oci systemd hooks, see https://developers.redhat.com/blog/2016/09/13/running-systemd-in-a-non-privileged-container/
	# HINT: swap must be disabled: swapoff -a
	KUBE_TOKEN=${KUBE_TOKEN:=$(docker run --rm ${KUBE_IMAGE} kubeadm token generate)} || exit 2
	[ "${KUBE_TOKEN}" ] || { echo KUBE_TOKEN not set and cannot not be derived >&2; exit 1; }
	initCA &&
	mkdir -p -m 0755 docker-data &&
	docker run -d --name kube-master --rm --privileged --net=host \
		-v /sys/fs/cgroup:/sys/fs/cgroup:rw \
		-v /lib/modules:/lib/modules:ro \
		-v /boot:/boot:ro \
		-v /etc/machine-id:/etc/machine-id:ro \
		-v ${RESOLV_CONF}:/etc/resolv.conf:ro \
		-v `pwd`/ca-cert/ca.key:/etc/kubernetes/pki/ca.key:ro \
		-v `pwd`/ca-cert/ca.crt:/etc/kubernetes/pki/ca.crt:ro \
		-v `pwd`/conf/manifests:/etc/kubernetes/custom:ro \
		-v `pwd`/docker-data:/var/lib/docker:rw \
		-v $HOME/.kube:/root/.kube \
		--tmpfs /run \
		--tmpfs /tmp \
		-e KUBE_TYPE=master \
		-e KUBE_TOKEN="${KUBE_TOKEN}" \
		${KUBE_IMAGE}
	#--net=kubeclusternet --ip ${KUBE_MASTER_IP}
}

startNode() {
	[ "${KUBE_MASTER_IP}" ] || { echo KUBE_MASTER_IP not set >&2; exit 1; }
	[ "${KUBE_TOKEN}" ] || { echo KUBE_TOKEN not set >&2; exit 1; }
	KUBE_CA_CERT_HASH=${KUBE_CA_CERT_HASH:=sha256:$(openssl x509 -in ca-cert/ca.crt -noout -pubkey | openssl rsa -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)} || exit 2
	docker run -d --name kube-node --rm --privileged --net=kubeclusternet --link kube-master \
		-v /sys/fs/cgroup:/sys/fs/cgroup:rw \
		-v /lib/modules:/lib/modules:ro \
		-v /boot:/boot:ro \
		-v ${RESOLV_CONF}:/etc/resolv.conf \
		-v $HOME/.kube:/root/.kube \
		--tmpfs /run \
		--tmpfs /tmp \
		-e KUBE_TYPE=node \
		-e KUBE_MASTER="${KUBE_MASTER_IP}:6443" \
		-e KUBE_TOKEN="${KUBE_TOKEN}" \
		-e KUBE_CA_CERT_HASH="${KUBE_CA_CERT_HASH}" \
		${KUBE_IMAGE}
# -v /sys/fs/cgroup/systemd:/sys/fs/cgroup/systemd:rw
}

stopNode() {
	docker stop kube-node &&
	docker rm kube-node
}

stopMaster() {
	docker stop kube-master &&
	docker rm kube-master
}

clean() {
	stopNode || true
	stopMaster || true
	netRemove
}

installKubectl() {
	curl -L https://storage.googleapis.com/kubernetes-release/release/v1.13.2/bin/linux/amd64/kubectl > /usr/local/bin/kubectl &&
	chmod 754 /usr/local/bin/kubectl &&
	chown root:docker /usr/local/bin/kubectl
}

proxy() {
	echo '#' Browse http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/
	kubectl proxy
}

dashboardToken() {
	kubectl -n kube-system describe secret `kubectl -n kube-system get secret | grep kubernetes-dashboard-token | awk '{print $1}'`
}

adminToken() {
	kubectl -n kube-system describe secret `kubectl -n kube-system get secret | grep admin-user-token | awk '{print $1}'`
}

if [ "$1" ]; then
	set -x
	$@
else
	set -x
	build &&
	initCA &&
	netCreate &&
	startMaster &&
	startNode
fi
