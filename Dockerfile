FROM debian:9

RUN apt-get update

# Install docker
RUN apt-get install -yq apt-transport-https ca-certificates curl gnupg2 software-properties-common
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add - && apt-key fingerprint 0EBFCD88
RUN add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/debian \
   $(lsb_release -cs) \
   stable"
RUN apt-get update && apt-get install -yq docker-ce

# Install CNI
ENV CNI_VERSION=v0.6.0
RUN mkdir -p /opt/cni/bin \
	&& curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-amd64-${CNI_VERSION}.tgz" | tar -C /opt/cni/bin -xz

# Install crictl (required for kubeadm / Kubelet Container Runtime Interface (CRI))
ENV CRICTL_VERSION=v1.11.1
RUN mkdir -p /opt/bin \
	&& curl -L "https://github.com/kubernetes-incubator/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" | tar -C /opt/bin -xz

# Install kubeadm, kubelet, kubectl
RUN export RELEASE="$(curl -sSL https://dl.k8s.io/release/stable.txt)" \
	&& mkdir -p /opt/bin \
	&& cd /opt/bin \
	&& curl -L --remote-name-all https://storage.googleapis.com/kubernetes-release/release/${RELEASE}/bin/linux/amd64/{kubeadm,kubelet,kubectl} \
	&& chmod +x kubeadm kubelet kubectl \
	&& curl -sSL "https://raw.githubusercontent.com/kubernetes/kubernetes/${RELEASE}/build/debs/kubelet.service" | sed "s:/usr/bin:/opt/bin:g" > /etc/systemd/system/kubelet.service \
	&& mkdir -p /etc/systemd/system/kubelet.service.d \
	&& curl -sSL "https://raw.githubusercontent.com/kubernetes/kubernetes/${RELEASE}/build/debs/10-kubeadm.conf" | sed "s:/usr/bin:/opt/bin:g" > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

# Install systemd
ENV container docker
RUN apt-get install -yq systemd \
	&& (cd /lib/systemd/system/sysinit.target.wants/; for i in *; do [ $i = systemd-tmpfiles-setup.service ] || rm -f $i; done) \
	&& rm -f /lib/systemd/system/multi-user.target.wants/* \
	&& rm -f /etc/systemd/system/*.wants/* \
	&& rm -f /lib/systemd/system/local-fs.target.wants/* \
	&& rm -f /lib/systemd/system/sockets.target.wants/*udev* \
	&& rm -f /lib/systemd/system/sockets.target.wants/*initctl* \
	&& rm -f /lib/systemd/system/basic.target.wants/* \
	&& rm -f /lib/systemd/system/anaconda.target.wants/*
VOLUME [ "/sys/fs/cgroup" ]

STOPSIGNAL SIGRTMIN+3

#CMD ["minikube", "start", "--vm-driver=none"]
#CMD [ "/usr/sbin/init" ]
CMD [ "/bin/systemd" ]
