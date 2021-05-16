#!/bin/sh

set -eu

KUBEAINER_APPS=${KUBEAINER_APPS:-/etc/kubeainer/apps}

usage() {
	echo "Usage: $0 {install [APP...]|kubeconfig}" >&2
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
	# use mounted kubeconfig secret when not running on master node
	[ -f /output/kubeconfig.yaml ] || export KUBECONFIG=/secrets/kubeconfig.yaml
	kubectl wait --for condition=ready --timeout 160s node/$(cat /etc/hostname) >/dev/null \
		|| (echo kube-system pods:; kubectl -n kube-system get pods; false) \
		|| (echo nodes:; kubectl get nodes; false) \
		|| die "node $(cat /etc/hostname) did not become ready!"
}

# ARGS: SECONDS CMD...
retry() {
	SECONDS="$1"
	shift
	for i in $(seq 0 "$SECONDS"); do
		"$@" >/dev/null 2>&1 && return 0
		sleep 1
	done
	echo "ERROR: timed out after $SECONDS attempts: $@" >&2
	"$@"
}

exportKubeconfig() {
	cp -f /etc/kubernetes/admin.conf /output/kubeconfig.yaml
	chown $(stat -c '%u' /output) /output/kubeconfig.yaml
}

installApps() {
	for APP in "$@"; do
		installApp "$APP"
	done
}

#installHostDNS() {
#	[ -f /host/etc/systemd/resolv.conf ] || die /host/etc/systemd/resolv.conf is not present
#}

# ARGS: APP_NAME_OR_DIR
appDir() {
	APP_DIR="$1"
	[ -d "$APP_DIR" ] || APP_DIR="$KUBEAINER_APPS/$1"
	[ -d "$APP_DIR" ] || (echo "ERROR: App '$1' not found! Supported apps: $(ls $KUBEAINER_APPS | xargs)" >&2; false)
	echo "$APP_DIR"
}

# ARG: MANIFEST_DIR
installApp() {
	APP_DIR="$(appDir "$1")"
	echo Installing $1
	[ -f "$APP_DIR/inventory-template.yaml" ] || kpt live init "$APP_DIR"
	kpt live apply "$APP_DIR" >/dev/null 2>&1 || kpt live apply "$APP_DIR"
	[ ! -f "$APP_DIR/post-apply-hook.sh" ] || (cd "$APP_DIR" && sh ./post-apply-hook.sh)
	kpt live status --poll-until=current --timeout=90s "$APP_DIR" >/dev/null || die "Failed to deploy app $1!"
	[ ! -f "$APP_DIR/post-install-hook.sh" ] || (cd "$APP_DIR" && sh ./post-install-hook.sh)
}

case "${1:-}" in
	install)
		shift
		waitForSystemdServices
		waitForNodes
		installApps "$@"
		echo 'The cluster is ready. Run `export KUBECONFIG=$PWD/kubeconfig.yaml` to use it'
	;;
	install-app)
		shift
		installApps "$@"
	;;
	retry)
		SECONDS="$2"
		shift 2
		retry "$SECONDS" "$@"
	;;
	export-kubeconfig)
		exportKubeconfig
	;;
	kubeconfig)
		[ -f /output/kubeconfig.yaml ] || exportKubeconfig
		cat /output/kubeconfig.yaml
	;;
	help)
		usage
	;;
	*)
		usage
		exit 1
	;;
esac
