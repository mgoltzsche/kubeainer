FROM debian:9-slim

RUN apt-get update \
	&& apt-get install -yq iproute ebtables ethtool socat openssl

# Install docker
ARG DOCKER_VERSION=18.06.1~ce~3-0~debian
RUN apt-get install -yq apt-transport-https ca-certificates curl gnupg2 software-properties-common \
	&& curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add - && apt-key fingerprint 0EBFCD88 \
	&& add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
	&& apt-get update \
	&& apt-get install -yq docker-ce=${DOCKER_VERSION}

# Install CNI plugins
ARG CNI_VERSION=v0.6.0
RUN mkdir -p /opt/cni/bin \
	&& curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-amd64-${CNI_VERSION}.tgz" | tar -C /opt/cni/bin -xz

# Install crictl (required for kubeadm / Kubelet Container Runtime Interface (CRI))
ARG CRICTL_VERSION=v1.11.1
RUN mkdir -p /opt/bin \
	&& curl -L "https://github.com/kubernetes-incubator/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" | tar -C /opt/bin -xz

# Install kubeadm, kubelet, kubectl
# (for latest stable version see https://storage.googleapis.com/kubernetes-release/release/stable.txt)
ARG K8S_VERSION=v1.13.2
RUN mkdir -p /opt/bin \
	&& cd /opt/bin \
	&& curl -L --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/{kubeadm,kubelet,kubectl} \
	&& chmod +x kubeadm kubelet kubectl \
	&& mkdir -p /etc/kubernetes/manifests

# Install systemd
ENV container docker
RUN apt-get install -yq systemd \
	&& cd /lib/systemd/system/sysinit.target.wants/; ls | grep -v systemd-tmpfiles-setup | xargs rm -f $1 \
	&& rm -f /etc/systemd/system/*.wants/* \
		/lib/systemd/system/multi-user.target.wants/* \
		/lib/systemd/system/local-fs.target.wants/* \
		/lib/systemd/system/sockets.target.wants/*udev* \
		/lib/systemd/system/sockets.target.wants/*initctl* \
		/lib/systemd/system/basic.target.wants/* \
		/lib/systemd/system/getty.target.wants/* \
		/lib/systemd/system/timers.target.wants/* \
		/lib/systemd/system/system-update.target.wants/* \
		/lib/systemd/system/systemd-update-utmp* \
	&& systemctl set-default multi-user.target
VOLUME /sys/fs/cgroup
# PROBLEM: systemd bootstrap times out waiting for block devices for some reason

STOPSIGNAL SIGRTMIN+3
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin
ENV KUBE_TYPE=master

# Enable systemd services
COPY conf/systemd/* /etc/systemd/system/
RUN systemctl enable docker kubelet kubeadm

# Make init script appear as systemd init process to support OCI hooks oci-systemd-hook and oci-register-machine
COPY entrypoint.sh /usr/sbin/init
COPY setup.sh /setup.sh

VOLUME /var/lib/docker

CMD [ "/usr/sbin/init" ]
