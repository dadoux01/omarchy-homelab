# Runs on the homelab host through `ssh host sh -s`, prefixed by the local
# helper with ACTION=... and NAME=... lines it has already validated.
if docker info >/dev/null 2>&1; then D="docker"
elif sudo -n docker info >/dev/null 2>&1; then D="sudo -n docker"
elif command -v podman >/dev/null 2>&1; then D="podman"
else echo "no access to docker" >&2; exit 3
fi
$D "$ACTION" "$NAME" >/dev/null
