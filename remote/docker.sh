# Runs on the homelab host through `ssh host sh -s`. Lists containers as
# "c<TAB>name<TAB>image<TAB>state<TAB>status<TAB>ports<TAB>created" and, for running ones,
# "s<TAB>name<TAB>cpu%<TAB>mem usage" records.
# Uses docker directly, then passwordless sudo, then podman.
if docker info >/dev/null 2>&1; then D="docker"
elif sudo -n docker info >/dev/null 2>&1; then D="sudo -n docker"
elif command -v podman >/dev/null 2>&1; then D="podman"
elif command -v docker >/dev/null 2>&1; then echo "error	noaccess"; exit 3
else echo "error	missing"; exit 3
fi

$D ps -a --format '{{.Names}}	{{.Image}}	{{.State}}	{{.Status}}	{{.Ports}}	{{.CreatedAt}}' 2>/dev/null | head -n 200 | sed 's/^/c	/'
$D stats --no-stream --format '{{.Name}}	{{.CPUPerc}}	{{.MemUsage}}' 2>/dev/null | head -n 200 | sed 's/^/s	/'
exit 0
