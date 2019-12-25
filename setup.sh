#!/bin/sh

# See https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/

# TODO: Skip if already set up

set -e

# Validate env
[ ! -z "$KUBE_TOKEN" ] || (echo 'KUBE_TOKEN is not set' >&2; false)

loadImages() {
	[ ! -f /preloaded/images.tar ] || docker load -i /preloaded/images.tar
}

initMaster() {
	[ -f /etc/kubernetes/pki/ca.crt ] || (echo 'CA pub key /etc/kubernetes/pki/ca.crt does not exist' >&2; false)
	[ -f /etc/kubernetes/pki/ca.key ] || (echo 'CA priv key /etc/kubernetes/pki/ca.key does not exist' >&2; false)
	# ignoring missing bridge feature since it just doesn't show up within a network namespace due to a kernel bug but is functional
	set -x
	loadImages
	[ "$K8S_VERSION" ] || (echo 'K8S_VERSION not set' >&2; false) || exit 1
	# see https://github.com/cri-o/cri-o/blob/master/tutorials/kubeadm.md
	# TODO: move apiserver cgroup below container's cgroup as well:
	# --resource-container option, e.g. as in https://github.com/kubernetes-retired/kubeadm-dind-cluster/blob/master/image/kubeadm.conf.1.13.tmpl
	kubeadm init --token="$KUBE_TOKEN" \
		--pod-network-cidr=10.244.0.0/16 \
		--ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables \
		--kubernetes-version=$K8S_VERSION
	mkdir -p /root/.kube /output
	cp -f /etc/kubernetes/admin.conf /root/.kube/config
	cp -f /etc/kubernetes/admin.conf /output/kubeconfig.yaml
	chown $(stat -c '%u' /output) /output/kubeconfig.yaml

	# Untaint master node to schedule pods
	kubectl taint node "$(cat /etc/hostname)" node-role.kubernetes.io/master-

	#installWeaveNetworking
	#installCertManager &&
	#kubectl apply -f /etc/kubernetes/custom &&
	#installLinkerd &&
	#installHelm
	#installRookCeph &&
	#installElasticStack
	#installJenkins
}

initNode() {
	[ ! -z "$KUBE_MASTER" ] || (echo 'KUBE_MASTER is not set' >&2; false)
	[ ! -z "$KUBE_CA_CERT_HASH" ] || (echo 'KUBE_CA_CERT_HASH is not set' >&2; false)
	set -x
	loadImages
	#mkdir -p /persistent-volumes/jenkins
	kubeadm join "$KUBE_MASTER" --token="$KUBE_TOKEN" --discovery-token-ca-cert-hash="$KUBE_CA_CERT_HASH" --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables
}

installWeaveNetworking() {
	kubectl apply --wait=true --timeout=2m -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
	#kubectl wait -n kube-system --for condition=ready pods -l name=weave-net
}

installFlannel() {
	# Alternative: requires kubeadm init --pod-network-cidr=10.244.0.0/16 set
	# see https://github.com/coreos/flannel/blob/master/Documentation/kubernetes.md
	kubectl apply --wait --timeout 2m -f https://raw.githubusercontent.com/coreos/flannel/v0.11.0/Documentation/kube-flannel.yml
}

# args: MANIFESTURL [TIMEOUT]
waitUntilAvailable() {
	# TODO: make it work for both cases: a) no match b) matches
	kubectl get -f "$1" -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} -n "{.metadata.namespace}"{"\n"}{end}' |
		grep -E '^Deployment/|APIService/' |
		while read LINE; do
			kubectl wait --for condition=available --timeout "${2:-2m}" $LINE
		done

	#kubectl get -f "$1" -o go-template=$'{{range .items}}{{if (eq .kind "Deployment" "APIService")}}-n "{{if .metadata.namespace}}{{.metadata.namespace}}{{end}}" {{.kind}}/{{.metadata.name}}\n{{end}}{{end}}' |
	#	xargs -n3 kubectl wait --for condition=available --timeout "${2:-2m}"
}

installCertManager() {
	# See https://docs.cert-manager.io/en/release-0.7/getting-started/index.html
	# see for kustomize https://blog.jetstack.io/blog/kustomize-cert-manager/
	# (kustomize currently doesn't work for complete cert-manager setup: https://github.com/kubernetes-sigs/kustomize/issues/821)
	#kubectl apply --wait --timeout=2m -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.7/deploy/manifests/cert-manager.yaml
	#kubectl kustomize /etc/kubernetes/kustomize/cert-manager/overlays/production_old | kubectl apply --wait --timeout=2m -f - --validate=false
	kubectl apply --wait --timeout=2m -rf /etc/kubernetes/kustomize/cert-manager
	waitUntilAvailable /etc/kubernetes/kustomize/cert-manager 5m
	kubectl apply --wait --timeout=30s -f /etc/kubernetes/kustomize/cert-manager-issuer
	
	#kubectl wait --for condition=available --timeout 5m -n cert-manager \
	#	deploy/cert-manager \
	#	deploy/cert-manager-webhook \
	#	deploy/cert-manager-cainjector \
	#	apiservice/v1beta1.admission.certmanager.k8s.io
}

installLinkerd() {
	kubectl wait --for condition=available apiservice/v1beta1.admissionregistration.k8s.io
	linkerd check --pre
	linkerd install --proxy-auto-inject | kubectl apply -f -
	linkerd check
	kubectl apply -f - <<-EOF
# See https://linkerd.io/2/tasks/exposing-dashboard/
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: web-ingress
  namespace: linkerd
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header l5d-dst-override $service_name.$namespace.svc.cluster.local:8084;
      proxy_set_header Origin "";
      proxy_hide_header l5d-remote-ip;
      proxy_hide_header l5d-server-id;
    #nginx.ingress.kubernetes.io/auth-type: basic
    #nginx.ingress.kubernetes.io/auth-secret: web-ingress-auth
    #nginx.ingress.kubernetes.io/auth-realm: "Authentication Required"
spec:
  rules:
  - host: linkerd.algorythm.de
    http:
      paths:
      - backend:
          serviceName: linkerd-web
          servicePort: 8084
  tls:
    - hosts:
        - linkerd.algorythm.de
      secretName: linkerd-dashboard-tls
	EOF
}

installHelm() {
	# TODO: secure tiller access, see https://docs.helm.sh/using_helm/#best-practices-for-securing-helm-and-tiller
	helm init --wait --service-account tiller --override 'spec.template.spec.containers[0].command'='{/tiller,--storage=secret}'
		#--tiller-tls \
		#--tiller-tls-verify \
		#--tiller-tls-cert=cert.pem \
		#--tiller-tls-key=key.pem \
		#--tls-ca-cert=ca.pem
	helm repo update
}

installRookCeph() {
	([ -d /etc/kubernetes/helm/ceph-operator/charts ] || (
		helm repo add rook-stable https://charts.rook.io/stable
		cd /etc/kubernetes/helm/ceph-operator
		helm dependencies update
	))
	kubectl create namespace rook-ceph-system
	helm install --name=rook-ceph --namespace rook-ceph-system /etc/kubernetes/helm/ceph-operator
	kubectl wait --for condition=available --timeout 5m apiservice/v1.ceph.rook.io
	kubectl create -f /etc/kubernetes/helm/ceph-operator/10-cluster.yaml
	kubectl apply -f /etc/kubernetes/helm/ceph-operator/20-toolbox.yaml
	kubectl create -f /etc/kubernetes/helm/ceph-operator/30-storageclass.yaml
	#kubectl create -f /etc/kubernetes/helm/ceph-operator/40-pvc.yaml
}

installElasticStack() {
	([ -d /etc/kubernetes/helm/efk/charts ] || (
		cd /etc/kubernetes/helm/efk
		helm dependencies update
	))
	kubectl create namespace logging
	helm install --name efk --namespace logging /etc/kubernetes/helm/efk
}

installJenkins() {
	# Fetch jenkins dependendencies
	[ -f /etc/kubernetes/helm/jenkins/charts ] || (
		cd /etc/kubernetes/helm/jenkins
		helm dependencies update
	) || return 1

	# Install Jenkins (see https://github.com/helm/charts/tree/master/stable/jenkins)
	helm install --name jenkins /etc/kubernetes/helm/jenkins
	#   or
	#helm install --name jenkins stable/jenkins -f /etc/kubernetes/helm/jenkins-values.yaml
	#helm install --name jenkins stable/jenkins --set Master.ServiceType=ClusterIP,Master.HostName=jenkins.algorythm.de,Master.ImageTag=lts-alpine,rbac.install=true,rbac.serviceAccountName=jenkins,Agent.Enabled=true,Agent.Image=mgoltzsche/jenkins-jnlp-slave,Agent.ImageTag=latest,Agent.Privileged=true,Persistence.Size=1Gi,Persistence.StorageClass=local-storage
	#  or (without using tiller)
	#helm dependencies update /etc/kubernetes/helm/jenkins
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
