#!/bin/sh

# See https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/

# TODO: Skip if already set up

# Validate env
[ ! -z "$KUBE_TOKEN" ] || (echo 'KUBE_TOKEN is not set' >&2; false) || exit 1

loadImages() {
	[ ! -f /preloaded/images.tar ] || docker load -i /preloaded/images.tar
}

initMaster() {
	[ -f /etc/kubernetes/pki/ca.crt ] || (echo 'CA pub key /etc/kubernetes/pki/ca.crt does not exist' >&2; false) || exit 1
	[ -f /etc/kubernetes/pki/ca.key ] || (echo 'CA priv key /etc/kubernetes/pki/ca.key does not exist' >&2; false) || exit 1
	# ignoring missing bridge feature since it just doesn't show up within a network namespace due to a kernel bug but is functional
	set -x
	loadImages &&
	kubeadm init --token="$KUBE_TOKEN" --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables &&
	mkdir -p /root/.kube &&
	cp -f /etc/kubernetes/admin.conf /root/.kube/config &&

	# Untaint master node to schedule pods
	kubectl taint node $(hostname) node-role.kubernetes.io/master-

	installWeaveNetworking &&
	installCertManager &&
	#installKubernetesDashboard &&
	kubectl apply -f /etc/kubernetes/custom &&
	installHelm &&
	installRookCeph &&
	installElasticStack
	#installJenkins
}

initNode() {
	[ ! -z "$KUBE_MASTER" ] || (echo 'KUBE_MASTER is not set' >&2; false) || exit 1
	[ ! -z "$KUBE_CA_CERT_HASH" ] || (echo 'KUBE_CA_CERT_HASH is not set' >&2; false) || exit 1
	set -x
	loadImages &&
	#mkdir -p /persistent-volumes/jenkins &&
	kubeadm join "$KUBE_MASTER" --token="$KUBE_TOKEN" --discovery-token-ca-cert-hash="$KUBE_CA_CERT_HASH" --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables
}

installWeaveNetworking() {
	kubectl apply --wait=true --timeout=2m -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
	#kubectl wait -n kube-system --for condition=ready pods -l name=weave-net &&
}

installKubernetesDashboard() {
	true
	#kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/aio/deploy/recommended/kubernetes-dashboard.yaml &&
	#kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/provider/baremetal/service-nodeport.yaml
}

installCertManager() {
	# Setup cert-manager issuer for namespace only (use namespaced issuer "ClusterIssuer" for single-tenant cluster)
	# See https://docs.cert-manager.io/en/release-0.7/getting-started/index.html
	kubectl apply --wait=true --timeout=2m -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.7/deploy/manifests/cert-manager.yaml &&
	kubectl wait --for condition=available --timeout 5m -n cert-manager deploy cert-manager cert-manager-webhook cert-manager-cainjector &&

	# Add ca as secret for ca-issuer (convert key since kubernetes tls secret only supports pkcs1 format)
	openssl rsa -in /etc/kubernetes/pki/ca.key -out /etc/kubernetes/pki/ca-rsa.key &&
	kubectl create secret tls cluster-ca-key-pair --cert=/etc/kubernetes/pki/ca.crt --key=/etc/kubernetes/pki/ca-rsa.key --namespace=cert-manager &&
	kubectl create secret tls ca-key-pair --cert=/etc/kubernetes/pki/ca.crt --key=/etc/kubernetes/pki/ca-rsa.key --namespace=default &&

	# Wait for cert-manager apiservice to become available (before applying issuer)
	kubectl wait --for condition=available --timeout 7m apiservice v1beta1.admission.certmanager.k8s.io
}

installHelm() {
	# TODO: secure tiller access, see https://docs.helm.sh/using_helm/#best-practices-for-securing-helm-and-tiller
	helm init --wait --service-account tiller --override 'spec.template.spec.containers[0].command'='{/tiller,--storage=secret}' &&
		#--tiller-tls \
		#--tiller-tls-verify \
		#--tiller-tls-cert=cert.pem \
		#--tiller-tls-key=key.pem \
		#--tls-ca-cert=ca.pem
	helm repo update
}

installRookCeph() {
	([ -d /etc/kubernetes/helm/ceph-operator/charts ] || (
		helm repo add rook-stable https://charts.rook.io/stable &&
		cd /etc/kubernetes/helm/ceph-operator &&
		helm dependencies update
	)) &&
	kubectl create namespace rook-ceph-system &&
	helm install --name=rook-ceph --namespace rook-ceph-system /etc/kubernetes/helm/ceph-operator &&
	kubectl wait --for condition=available --timeout 5m apiservice/v1.ceph.rook.io &&
	kubectl create -f /etc/kubernetes/helm/ceph-operator/10-cluster.yaml &&
	kubectl apply -f /etc/kubernetes/helm/ceph-operator/20-toolbox.yaml &&
	kubectl create -f /etc/kubernetes/helm/ceph-operator/30-storageclass.yaml
	#kubectl create -f /etc/kubernetes/helm/ceph-operator/40-pvc.yaml
}

installElasticStack() {
	([ -d /etc/kubernetes/helm/efk/charts ] || (
		cd /etc/kubernetes/helm/efk &&
		helm dependencies update
	)) &&
	kubectl create namespace logging &&
	helm install --name efk --namespace logging /etc/kubernetes/helm/efk
}

installJenkins() {
	# Fetch jenkins dependendencies
	[ -f /etc/kubernetes/helm/jenkins/charts ] || (
		cd /etc/kubernetes/helm/cephfs &&
		helm dependencies update
	) || return 1

	# Install Jenkins (see https://github.com/helm/charts/tree/master/stable/jenkins)
	helm install --name jenkins /etc/kubernetes/helm/jenkins
	#   or
	#helm install --name jenkins stable/jenkins -f /etc/kubernetes/helm/jenkins-values.yaml
	#helm install --name jenkins stable/jenkins --set Master.ServiceType=ClusterIP,Master.HostName=jenkins.algorythm.de,Master.ImageTag=lts-alpine,rbac.install=true,rbac.serviceAccountName=jenkins,Agent.Enabled=true,Agent.Image=mgoltzsche/jenkins-jnlp-slave,Agent.ImageTag=latest,Agent.Privileged=true,Persistence.Size=1Gi,Persistence.StorageClass=local-storage
	#  or (without using tiller)
	#helm dependencies update /etc/kubernetes/helm/jenkins &&
	#helm template -n devrelease -f /etc/kubernetes/helm/jenkins/values.yaml /etc/kubernetes/helm/jenkins | kubectl apply -f -
	#PROBLEM: resources with generated values change every rendering run -> old resources (as tests) not deleted
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
