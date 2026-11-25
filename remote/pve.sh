# Runs on a Proxmox VE node through `ssh host sh -s`. Read-only: prints the
# cluster's resources (nodes, VMs, containers, storage), recent tasks and the
# version as JSON sections the plugin parses:
#   == resources / == tasks / == version, each followed by one JSON line.
# pvesh needs root, so this uses root or passwordless sudo, nothing else.
if [ "$(id -u)" = 0 ]; then P="pvesh"
elif sudo -n true >/dev/null 2>&1; then P="sudo -n pvesh"
else echo "error	noaccess"; exit 5
fi
command -v pvesh >/dev/null 2>&1 || { echo "error	notpve"; exit 5; }

echo "== resources"
$P get /cluster/resources --output-format json 2>/dev/null || echo "[]"
echo
echo "== tasks"
$P get /cluster/tasks --output-format json 2>/dev/null || echo "[]"
echo
echo "== version"
$P get /version --output-format json 2>/dev/null || echo "{}"
echo
