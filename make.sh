#!/bin/sh

set -e
	: ${KUBE_IMAGE:=local/kubernetes}
	: ${KUBE_NET:=10.23.0.0/16}
	: ${KUBE_MASTER_IP:=10.23.0.2}
	#: ${KUBE_MASTER_IP:=`ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n'`}
	# Use original resolv.conf (uncached)
	: ${RESOLV_CONF:=$(find /etc/resolvconf/resolv.conf.d/original /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null | head -1)}
	: ${CA_CN:=example.org}

K8S_VERSION=v1.17.4
HELM_VERSION=v2.13.1
IMAGES='k8s.gcr.io/kube-apiserver:v1.13.2
		k8s.gcr.io/kube-proxy:v1.13.2
		k8s.gcr.io/kube-controller-manager:v1.13.2
		k8s.gcr.io/kube-scheduler:v1.13.2
		k8s.gcr.io/kubernetes-dashboard-amd64:v1.10.1
		k8s.gcr.io/coredns:1.2.6
		k8s.gcr.io/etcd:3.2.24
		k8s.gcr.io/pause:3.1
		weaveworks/weave-npc:2.5.1
		weaveworks/weave-kube:2.5.1
		quay.io/jetstack/cert-manager-controller:v0.6.0
		quay.io/jetstack/cert-manager-webhook:v0.6.0
		quay.io/munnerz/apiextensions-ca-helper:v0.1.0
		quay.io/kubernetes-ingress-controller/nginx-ingress-controller:0.22.0
		gcr.io/kubernetes-helm/tiller:canary
		jenkins/jenkins:lts-alpine
		mgoltzsche/jenkins-jnlp-slave:latest'

build() {
	loadImages &&
	docker build --force-rm -t ${KUBE_IMAGE} .
}

loadImages() {
	[ -f preloaded/images.tar ] ||
	(mkdir -p preloaded &&
	echo ${IMAGES} | xargs -n1 docker image pull &&
	docker save ${IMAGES} > preloaded/images.tar)
}

reloadImages() {
	docker save ${IMAGES} > preloaded/images.tar &&
	docker exec kube-master docker load -i /preloaded/images.tar &&
	docker exec kube-node   docker load -i /preloaded/images.tar
}

initCA() {
	[ ! -f ca-cert/ca.key ] || return 0
	mkdir -p ca-cert
	openssl req -x509 -nodes -newkey rsa:2048 -subj "/CN=$CA_CN" \
		-config ca.conf -extensions v3_ca \
		-keyout ca-cert/ca.key -out ca-cert/ca.crt
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
	mkdir -p -m 0755 crio-data1 crio-data2 &&
	docker run -d --name kube-master --rm --privileged \
		--net=kubeclusternet --ip ${KUBE_MASTER_IP} --hostname kube-master \
		-v /lib/modules:/lib/modules:ro \
		-v /boot:/boot:ro \
		-v ${RESOLV_CONF}:/etc/resolv.conf:ro \
		-v `pwd`/ca-cert/ca.key:/etc/kubernetes/pki/ca.key:ro \
		-v `pwd`/ca-cert/ca.crt:/etc/kubernetes/pki/ca.crt:ro \
		-v `pwd`/crio-data1:/var/lib/containers:rw \
		-v `pwd`:/output:rw \
		--tmpfs /run \
		--tmpfs /tmp \
		-e KUBE_TYPE=master \
		-e KUBE_TOKEN="${KUBE_TOKEN}" \
		${KUBE_IMAGE}
}

startNode() {
	[ "${KUBE_MASTER_IP}" ] || { echo KUBE_MASTER_IP not set >&2; exit 1; }
	[ "${KUBE_TOKEN}" ] || { echo KUBE_TOKEN not set >&2; exit 1; }
	KUBE_CA_CERT_HASH=${KUBE_CA_CERT_HASH:=sha256:$(openssl x509 -in ca-cert/ca.crt -noout -pubkey | openssl rsa -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)} || exit 2
	docker run -d --name kube-node --hostname kube-node --rm --privileged \
		--net=kubeclusternet --link kube-master \
		-v /lib/modules:/lib/modules:ro \
		-v /boot:/boot:ro \
		-v ${RESOLV_CONF}:/etc/resolv.conf:ro \
		-v `pwd`/crio-data2:/var/lib/containers:rw \
		--tmpfs /run \
		--tmpfs /tmp \
		-e KUBE_TYPE=node \
		-e KUBE_MASTER="${KUBE_MASTER_IP}:6443" \
		-e KUBE_TOKEN="${KUBE_TOKEN}" \
		-e KUBE_CA_CERT_HASH="${KUBE_CA_CERT_HASH}" \
		${KUBE_IMAGE}
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
	netRemove || true
}

installKubectl() {
	curl -L https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kubectl > /usr/local/bin/kubectl &&
	chmod 754 /usr/local/bin/kubectl &&
	chown root:docker /usr/local/bin/kubectl
}

installHelm() {
	rm -rf /tmp/helm &&
	mkdir -p /tmp/helm &&
	curl -L https://storage.googleapis.com/kubernetes-helm/helm-${HELM_VERSION}-linux-amd64.tar.gz > /tmp/helm/helm.tar.gz &&
	tar -C /tmp/helm -zxvf /tmp/helm/helm.tar.gz &&
	mv /tmp/helm/linux-amd64/helm /usr/local/bin/helm &&
	rm -rf /tmp/helm
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
	while [ $# -gt 0 ]; do
		CMD="$1"
		shift
		(set -x; $CMD)
	done
else
	set -x
	build &&
	initCA &&
	netCreate &&
	startMaster &&
	startNode
fi
