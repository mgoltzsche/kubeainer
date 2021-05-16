#!/bin/sh

# See https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/

set -eu

SECRETS_DIR=/secrets
KUBE_TOKEN_FILE=$SECRETS_DIR/kube.token
KUBE_MASTER_IP_FILE=$SECRETS_DIR/kube.masterip
KUBE_CA_HASH_FILE=$SECRETS_DIR/kube.cahash

initMaster() {
	initCA
	KUBE_TOKEN="$(writeAtomicFile $KUBE_TOKEN_FILE kubeadm token generate)"
	KUBE_MASTER_IP="$(writeAtomicFile $KUBE_MASTER_IP_FILE getPublicIP)"
	echo Initializing Kubernetes $K8S_VERSION master
	set -x
	# ignoring missing bridge feature since it just doesn't show up within a network namespace due to a kernel bug but is functional
	# see https://github.com/cri-o/cri-o/blob/master/tutorials/kubeadm.md
	# TODO: move apiserver cgroup below container's cgroup as well:
	# --resource-container option, e.g. as in https://github.com/kubernetes-retired/kubeadm-dind-cluster/blob/master/image/kubeadm.conf.1.13.tmpl
	#		--node-name="$(cat /etc/hostname)" \
	# kubeadm options have been moved into the configuration
	# (because otherwise service-node-port-range cannot be set):
    #  --token="$KUBE_TOKEN"
	#  --service-dns-domain=cluster.local
	#  --pod-network-cidr=10.244.0.0/16
	#  --kubernetes-version=$K8S_VERSION
	# derived from `kubeadm config print init-defaults`
	cat - > /tmp/kubeadm.yaml <<-EOF
		apiVersion: kubeadm.k8s.io/v1beta2
		kind: InitConfiguration
		bootstrapTokens:
		- groups:
		  - system:bootstrappers:kubeadm:default-node-token
		  token: "$KUBE_TOKEN"
		  ttl: 24h0m0s
		  usages:
		  - signing
		  - authentication
		localAPIEndpoint:
		  advertiseAddress: "$KUBE_MASTER_IP"
		  bindPort: 6443
		nodeRegistration:
		  criSocket: /var/run/crio/crio.sock
		  name: "$(cat /etc/hostname)"
		  # allow to schedule pods on the master node as well (in production master nodes should be tainted!)
		  taints: []
		---
		apiVersion: kubeadm.k8s.io/v1beta2
		kind: ClusterConfiguration
		apiServer:
		  extraArgs:
		    authorization-mode: Node,RBAC
			# allow ingress-nginx to bind node ports 80 and 443 and external-dns to bind node port 53
		    service-node-port-range: 53-22767
		  timeoutForControlPlane: 4m0s
		certificatesDir: /etc/kubernetes/pki
		clusterName: kubernetes
		controllerManager: {}
		dns:
		  type: CoreDNS
		etcd:
		  local:
		    dataDir: /var/lib/etcd
		imageRepository: k8s.gcr.io
		kubernetesVersion: "$K8S_VERSION"
		networking:
		  dnsDomain: cluster.local
		  podSubnet: 10.244.0.0/16
		  serviceSubnet: 10.96.0.0/12
		scheduler: {}
	EOF
	kubeadm init --config=/tmp/kubeadm.yaml \
		--ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables \
		--ignore-preflight-errors=Swap \
		--ignore-preflight-errors=SystemVerification
	mkdir -p /root/.kube /output
	cp -f /etc/kubernetes/admin.conf /root/.kube/config
	cp -f /etc/kubernetes/admin.conf /secrets/kubeconfig.yaml
	kubeainer export-kubeconfig
	#enableCoreDNSPluginK8sExternal
	kubeainer install-app flannel
}

initNode() {
	[ -d $SECRETS_DIR ] || (echo ERROR: the directory $SECRETS_DIR does not exist but needs to be mounted into all node containers >&2; false)
	KUBE_CA_HASH="$(waitForFile $KUBE_CA_HASH_FILE)"
	KUBE_TOKEN="$(waitForFile $KUBE_TOKEN_FILE)"
	KUBE_MASTER_IP="$(waitForFile $KUBE_MASTER_IP_FILE)"
	KUBE_MASTER="$KUBE_MASTER_IP:6443"
	set -x
	kubeadm join "$KUBE_MASTER" --token="$KUBE_TOKEN" --discovery-token-ca-cert-hash="$KUBE_CA_HASH" \
		--cri-socket "/var/run/crio/crio.sock" \
		--ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables \
		--ignore-preflight-errors Swap \
		--ignore-preflight-errors SystemVerification
}

initCA() {
	([ -f $SECRETS_DIR/ca.crt ] && [ -f $SECRETS_DIR/ca.key ]) || (
		mkdir -p $SECRETS_DIR &&
		rm -f $SECRETS_DIR/ca.crt $SECRETS_DIR/ca.key $KUBE_CA_HASH_FILE &&
		openssl req -x509 -nodes -newkey rsa:2048 -subj "/CN=kube-fake-ca" \
			-config /etc/ssl/ca.cnf -extensions v3_ca \
			-keyout $SECRETS_DIR/ca.key -out $SECRETS_DIR/ca.crt
	)
	mkdir -p /etc/kubernetes/pki
	cp -f $SECRETS_DIR/ca.key /etc/kubernetes/pki/ca.key
	cp -f $SECRETS_DIR/ca.crt /etc/kubernetes/pki/ca.crt
	writeAtomicFile $KUBE_CA_HASH_FILE hashCA >/dev/null
}

hashCA() {
	echo sha256:$(openssl x509 -in $SECRETS_DIR/ca.crt -noout -pubkey | openssl rsa -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
}

# Args: FILE COMMAND
writeAtomicFile() {
	FILE="$1"
	shift
	[ -f $FILE ] || (
		mkdir -p $(dirname $FILE)
		TMPFILE=$(mktemp -p $(dirname $FILE)) &&
		"$@" > $TMPFILE &&
		mv $TMPFILE $FILE
		STATUS=$?
		rm -f $TMPFILE
		exit $STATUS
	)
	cat $FILE
}

getPublicIP() {
	ip -4 route get 8.8.8.8 | awk {'print $7'} | tr -d '\n'
}

# Args: FILE
waitForFile() {
	cat $1 2>/dev/null && return 0 || true
	echo Waiting for $1 to be written by master
	for i in $(seq 0 60); do
		sleep 1
		cat $1 2>/dev/null && return 0 || true
	done
	echo ERROR: Timed out waiting for $1 to be written by master >&2
	return 1
}

# Enables k8s_external coredns plugin to provide access to Services of type LoadBalancer under an external zone within the cluster and on nodes (required for e.g. registry)
enableCoreDNSPluginK8sExternal() {
	# original Corefile with k8s_external plugin enabled.
	# see https://github.com/coredns/coredns/tree/master/plugin/k8s_external
	kubectl apply -f - <<-EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        k8s_external svc.example.org
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
	EOF
}


# Init node
case "$KUBE_TYPE" in
	master)
		initMaster
	;;
	node)
		initNode
	;;
	*)
		echo "Unknown KUBE_TYPE value '$KUBE_TYPE'" >&2
		exit 1
	;;
esac
