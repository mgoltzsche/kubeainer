ARG K8S_VERSION=v1.16.4

#FROM golang:1.10-alpine AS cfssl
#RUN apk add --update --no-cache git build-base
#RUN git clone https://github.com/cloudflare/cfssl.git $GOPATH/src/github.com/cloudflare/cfssl --branch 1.3.2
#RUN go get github.com/cloudflare/cfssl_trust/... \
#	&& cp -R /go/src/github.com/cloudflare/cfssl_trust /etc/cfssl
#WORKDIR /go/src/github.com/cloudflare/cfssl
#RUN CGO_ENABLED=0 GOOS=linux go install -a -ldflags '-extldflags "-static"' ./cmd/...


# Build CRI-O
FROM golang:1.13-alpine3.10 AS crio
RUN apk add --update --no-cache git make gcc pkgconf musl-dev \
	btrfs-progs btrfs-progs-dev libassuan-dev lvm2-dev device-mapper \
	glib-static libc-dev gpgme-dev protobuf-dev protobuf-c-dev \
	libseccomp-dev libselinux-dev ostree-dev openssl iptables bash \
	go-md2man
#ARG CRIO_VERSION=v1.16.1
#RUN git clone --branch=$CRIO_VERSION https://github.com/cri-o/cri-o /go/src/github.com/cri-o/cri-o
ARG CRIO_VERSION=master
RUN git clone --branch=$CRIO_VERSION https://github.com/mgoltzsche/cri-o /go/src/github.com/cri-o/cri-o
WORKDIR /go/src/github.com/cri-o/cri-o
RUN set -ex; \
	make bin/crio bin/pinns bin/crio-status SHRINKFLAGS='-s -w -extldflags "-static"' BUILDTAGS='seccomp selinux varlink exclude_graphdriver_devicemapper containers_image_ostree_stub containers_image_openpgp'; \
	mv bin/* /usr/local/bin/; \
	mkdir -p /etc/sysconfig; \
	mv contrib/sysconfig/crio /etc/sysconfig/crio


FROM alpine:3.10 AS downloads
RUN apk add --update --no-cache curl tar

# Download CNI plugins
ARG CNI_PLUGIN_VERSION=v0.8.3
RUN mkdir -p /opt/cni/bin \
	&& curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGIN_VERSION}.tgz" | tar -C /opt/cni/bin -xz

# Download crictl (required for kubeadm / Kubelet Container Runtime Interface (CRI))
ARG CRICTL_VERSION=v1.16.1
RUN mkdir -p /opt/bin \
	&& curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" | tar -C /opt/bin -xz

# Download kubeadm, kubelet, kubectl
# (for latest stable version see https://storage.googleapis.com/kubernetes-release/release/stable.txt)
ARG K8S_VERSION
RUN mkdir -p /opt/bin \
	&& cd /opt/bin \
	&& curl -L --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/{kubeadm,kubelet,kubectl} \
	&& chmod +x kubeadm kubelet kubectl


FROM mgoltzsche/podman:1.6.4 AS podman


# Build final image
FROM registry.fedoraproject.org/fedora-minimal:30

# Install systemd and tools
# - conntrack required by CRI-O
# - network binaries required by CNI plugins
# - (file system utilities for playing around with ceph)
ENV container docker
RUN set -ex; \
	microdnf -y install systemd conntrack iptables iproute ebtables ethtool socat openssl xfsprogs e2fsprogs; \
	microdnf clean all; \
	systemctl --help >/dev/null

# Copy kubeadm, kubelet, kubectl, crictl and CNI plugins
COPY --from=downloads /opt/bin /opt/bin
COPY --from=downloads /opt/cni/bin /opt/cni/bin

# Copy crio & podman
COPY --from=crio /usr/local/bin/ /usr/local/bin/
COPY --from=crio /etc/sysconfig/crio /etc/sysconfig/crio
COPY --from=podman /usr/local/bin/runc /usr/local/bin/podman /usr/local/bin/
COPY --from=podman /usr/libexec/podman/conmon /usr/libexec/podman/conmon
#COPY --from=podman /usr/libexec/cni/loopback /usr/libexec/cni/flannel /usr/libexec/cni/bridge /usr/libexec/cni/portmap /opt/cni/bin/
COPY --from=podman /etc/containers /etc/containers
RUN set -ex; \
	mkdir -p /etc/crio /var/lib/crio /etc/kubernetes/manifests /usr/share/containers/oci/hooks.d; \
	crio --config="" config > /etc/crio/crio.conf; \
	ln -s /usr/libexec/podman/conmon /usr/local/bin/conmon
RUN set -ex; crio --help >/dev/null; runc --help >/dev/null; podman --help >/dev/null
COPY conf/sysctl.d /etc/sysctl.d
VOLUME ["/var/lib/containers"]

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin
ENV KUBE_TYPE=master
ARG K8S_VERSION
ENV K8S_VERSION=$K8S_VERSION

# Enable systemd services
COPY start-kubelet.sh /opt/bin/start-kubelet
COPY conf/systemd/* /etc/systemd/system/
RUN systemctl enable kubelet kubeadm crio crio-wipe crio-shutdown

# Make init script appear as systemd init process to support OCI hooks oci-systemd-hook and oci-register-machine
RUN mv /usr/sbin/init /usr/sbin/systemd
COPY entrypoint.sh /usr/sbin/init
COPY setup.sh /setup.sh

STOPSIGNAL 2
CMD ["/usr/sbin/init"]
