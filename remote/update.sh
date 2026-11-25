# Runs on the homelab host through `ssh host sh -s`, prefixed by the local
# helper with a validated NAME=... line. Pulls the container's image and, when
# it changed, recreates only that service through its Compose project.
# Last stdout line: updated | uptodate | error <reason>
if docker info >/dev/null 2>&1; then D="docker"
elif sudo -n docker info >/dev/null 2>&1; then D="sudo -n docker"
else echo "error noaccess"; exit 3
fi

image=$($D inspect -f '{{.Config.Image}}' "$NAME" 2>/dev/null) || { echo "error notfound"; exit 3; }
current=$($D inspect -f '{{.Image}}' "$NAME")

label() { $D inspect -f "{{index .Config.Labels \"$1\"}}" "$NAME"; }
project=$(label com.docker.compose.project)
service=$(label com.docker.compose.service)
workdir=$(label com.docker.compose.project.working_dir)
files=$(label com.docker.compose.project.config_files)

# A failed pull (registry rate limit, offline) is not fatal when a newer image
# was already pulled earlier and only the recreate is missing.
pulled=1
pullerr=$($D pull -q "$image" 2>&1 >/dev/null) || pulled=0
latest=$($D image inspect -f '{{.Id}}' "$image" 2>/dev/null)
if [ -z "$latest" ] || [ "$current" = "$latest" ]; then
  if [ "$pulled" = 1 ]; then echo "uptodate"; exit 0; fi
  echo "detail	$(printf '%s' "$pullerr" | tail -n 1 | cut -c1-300)"
  echo "error pull"; exit 4
fi

[ -n "$project" ] && [ -n "$service" ] || { echo "error nocompose"; exit 5; }

set --
old_ifs=$IFS; IFS=,
for f in $files; do set -- "$@" -f "$f"; done
IFS=$old_ifs
[ -n "$workdir" ] && set -- --project-directory "$workdir" "$@"

# Can this user read everything compose reads client-side? Stack managers
# such as Dockge write root-owned 600 .env files, which docker-group
# membership alone cannot read.
readable=1
old_ifs=$IFS; IFS=,
for f in $files; do [ -r "$f" ] || readable=0; done
IFS=$old_ifs
[ -e "$workdir/.env" ] && [ ! -r "$workdir/.env" ] && readable=0

# A running container with the Docker socket and the stack directory mounted
# at the same path (Dockge, …) can run compose as root for us.
find_runner() {
  $D ps --format '{{.Names}}' 2>/dev/null | while IFS= read -r c; do
    [ "$c" = "$NAME" ] && continue
    mounts=$($D inspect -f '{{range .Mounts}}{{.Source}}={{.Destination}};{{end}}' "$c" 2>/dev/null)
    case $mounts in *docker.sock*) ;; *) continue ;; esac
    printf '%s\n' "$mounts" | tr ';' '\n' | while IFS='=' read -r src dst; do
      [ -n "$src" ] && [ "$src" = "$dst" ] || continue
      case "$workdir/" in "$src"/*) echo "$c" ;; esac
    done
  done | while IFS= read -r c; do
    $D exec "$c" docker compose version >/dev/null 2>&1 && { echo "$c"; break; }
  done
}

err=$(mktemp)
run_up() {
  if [ "$readable" = 1 ] && $D compose version >/dev/null 2>&1; then
    via=direct
    $D compose -p "$project" "$@" up -d --no-deps "$service" >/dev/null 2>"$err"
  elif [ "$readable" = 1 ] && command -v docker-compose >/dev/null 2>&1; then
    via=docker-compose
    docker-compose -p "$project" "$@" up -d --no-deps "$service" >/dev/null 2>"$err"
  elif sudo -n true >/dev/null 2>&1; then
    via=sudo
    sudo -n docker compose -p "$project" "$@" up -d --no-deps "$service" >/dev/null 2>"$err"
  else
    runner=$(find_runner)
    if [ -n "$runner" ]; then
      via="container $runner"
      $D exec "$runner" docker compose -p "$project" "$@" up -d --no-deps "$service" >/dev/null 2>"$err"
    else
      via=none
      echo "cannot read the compose files or .env in $workdir as $(id -un), no passwordless sudo, and no stack manager container (Dockge…) to run compose" >"$err"
      return 1
    fi
  fi
}

if run_up "$@"; then
  rm -f "$err"
  echo "via	$via"
  echo "updated"
else
  detail=$(grep -v '^\s*$' "$err" | tail -n 1 | cut -c1-300)
  rm -f "$err"
  echo "detail	${detail:-compose up failed} (via $via)"
  echo "error recreate"
  exit 6
fi
