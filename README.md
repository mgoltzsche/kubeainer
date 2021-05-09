# Kubeainer

A [Kubernetes](https://github.com/kubernetes/kubernetes) container image and [Docker Compose](https://docs.docker.com/compose/compose-file/compose-file-v3/) project to spin up a local cluster for development and experimentation purposes.  

It uses upstream Kubernetes as well as [CRI-O](https://github.com/cri-o/cri-o) and initializes the cluster using [kubeadm](https://github.com/kubernetes/kubeadm).

## Usage

Build and run the container:
```sh
make image compose-up
```

Alternatively:
```sh
docker-compose up -d
docker-compose exec kube-master kubeainer install
```
_The `kubeainer install` command waits for the cluster initialization to complete and must be run within the container._

To install additional built-in addons run e.g.:
```sh
docker-compose exec kube-master kubeainer install local-path-provisioner metallb cert-manager
```

Once the cluster is initialized the Kubernetes client configuration is written to `$PWD/kubeconfig.yaml` (`$PWD` is the compose project's directory) and can be used as follows:
```sh
export KUBECONFIG=$PWD/kubeconfig.yaml
```
