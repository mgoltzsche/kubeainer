#!/bin/sh

set -eu

usage() {
	echo "Usage: $0 install [APP...]" >&2
}

# Args: MSG
die() {
	echo "ERROR: $1" >&2
	exit 1
}

# Args: SERVICE WAITMAXSECONDS
waitForSystemdService() {
	START_TIME=`date +%s`
	systemctl status $1 >/dev/null 2>&1 && return 0 || true
	printf 'Waiting for %s' $1
	for i in $(seq 0 $2); do
		sleep 1
		printf .
		systemctl status $1 >/dev/null && printf ' [completed in %ds]\n' $(expr $(date +%s) - $START_TIME) && return 0 || ! systemctl is-failed $1 >/dev/null \
			|| (printf '\n\nERROR: Service %s failed to start! Dumping logs...\n\n' $1 >&2; journalctl -u $1 | sed -E 's/^/  /g'; false) || return 1
	done
	printf '\n\nERROR: Timed out after %ds waiting for service %s to start! Dumping logs...\n\n' $2 $1 >&2
	journalctl -u $1 | sed -E 's/^/  /g'
	return 1
}

waitForSystemdServices() {
	waitForSystemdService crio 20
	waitForSystemdService kubeadm 240
}

waitForNodes() {
	echo Waiting for node to become ready
	kubectl wait --for condition=ready --timeout 120s node/$(cat /etc/hostname) >/dev/null || die "node did not become ready!"
}

case "${1:-}" in
	install)
		shift
		for APP in $@; do
			[ -d "/etc/kubernetes/apps/$APP" ] || die "Unsupported app '$APP'! Supported apps: $(ls /etc/kubernetes/apps | xargs)"
		done
		waitForSystemdServices
		waitForNodes
		for APP in $@; do
		    echo Installing $APP
			kubectl apply -k "/etc/kubernetes/apps/$APP" >/dev/null || die "Failed to install app $APP!"
		done
		echo 'The cluster is ready. Run `export KUBECONFIG=$PWD/kubeconfig.yaml` to use it'
	;;
	help)
		usage
	;;
	*)
		usage
		exit 1
	;;
esac
