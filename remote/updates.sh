# Runs on the homelab host through `ssh host sh -s`. Read-only: compares
# each container's image with its registry (manifest only, no pull), counts
# pending OS packages, and reports a pending reboot.
#   img<TAB>container<TAB>image<TAB>remote-digest
#   imgerr<TAB>image<TAB>reason       (ratelimit | other: registry unreachable, local build, …)
#   noimgcheck                        (docker buildx missing)
# The local helper prefixes MODE=all|packages; "packages" skips the image
# registry checks (fast, and spares Docker Hub's rate limit).
#   os / pkg                          (see "system packages" below)
#   sudo<TAB>1                        (passwordless sudo available)
#   reboot<TAB>1
#   busy<TAB>1                        (a package manager is running right now)
T=$(printf '\t')
LC_ALL=C
export LC_ALL

if docker info >/dev/null 2>&1; then D="docker"
elif sudo -n docker info >/dev/null 2>&1; then D="sudo -n docker"
else D=""
fi

if [ -n "$D" ] && [ "${MODE:-all}" != packages ]; then
  # One line per container: name, configured image (the tag it was created
  # from, even once that tag has moved on), running image id.
  tmp=$(mktemp -d)
  $D ps -aq 2>/dev/null | head -n 300 | while IFS= read -r id; do
    $D inspect -f '{{slice .Name 1}}	{{.Config.Image}}	{{.Image}}' "$id" 2>/dev/null
  done | sort > "$tmp/list"
  buildx=0
  $D buildx version >/dev/null 2>&1 && buildx=1
  [ "$buildx" = 1 ] || echo "noimgcheck"
  cut -f2 "$tmp/list" | sort -u | head -n 120 | while IFS= read -r image; do
    case $image in
      *@sha256:*|sha256:*) continue ;;
    esac
    tagid=$($D image inspect -f '{{.Id}}' "$image" 2>/dev/null)
    remote="" reason=other
    if [ "$buildx" = 1 ]; then
      answer=$(timeout 30 $D buildx imagetools inspect "$image" --format '{{json .Manifest}}' 2>&1)
      remote=$(printf '%s\n' "$answer" | sed -n 's/.*"digest": *"\(sha256:[0-9a-f]*\)".*/\1/p' | head -n 1)
      case $answer in *"429"*|*"Too Many Requests"*|*"toomanyrequests"*) reason=ratelimit ;; esac
    fi
    unchecked=0
    awk -F'\t' -v img="$image" '$2 == img { print $1 "\t" $3 }' "$tmp/list" > "$tmp/ctrs"
    while IFS="$T" read -r name running; do
      # The tag already points at a newer, pulled image: only a recreate is missing.
      if [ -n "$tagid" ] && [ "$running" != "$tagid" ]; then
        echo "img${T}${name}${T}${image}${T}local:${tagid}"
        continue
      fi
      if [ -z "$remote" ]; then unchecked=1; continue; fi
      digests=$($D image inspect -f '{{range .RepoDigests}}{{.}} {{end}}' "$running" 2>/dev/null)
      case " $digests" in
        *"@$remote "*) ;;
        *) echo "img${T}${name}${T}${image}${T}${remote}" ;;
      esac
    done < "$tmp/ctrs"
    [ "$unchecked" = 1 ] && echo "imgerr${T}${image}${T}${reason}"
  done
  rm -rf "$tmp"
fi

# ---------- system packages ----------
# One "os" record per package manager found (the distribution's own, plus
# Flatpak and Snap), each followed by its "pkg" records. Lists are refreshed
# without root wherever the manager allows it; "fresh" says whether that
# worked or the system's possibly stale metadata was used.
#   os<TAB>manager<TAB>count<TAB>security<TAB>lists-age-seconds(-1 unknown)<TAB>fresh(0|1)
#   pkg<TAB>name<TAB>new<TAB>current<TAB>security(0|1)<TAB>manager

now=$(date +%s)
mtime_age() {
  newest=0
  for f in "$@"; do
    t=$(stat -c %Y "$f" 2>/dev/null) && [ "$t" -gt "$newest" ] && newest=$t
  done
  [ "$newest" -gt 0 ] && echo $(( now - newest )) || echo -1
}

# stdin: name<TAB>new<TAB>current<TAB>security ; $1 manager, $2 age, $3 fresh
emit() {
  rows=$(cat)
  count=$(printf '%s' "$rows" | grep -c .)
  sec=${SECURITY_COUNT:-$(printf '%s\n' "$rows" | awk -F'\t' 'NF && $4 == 1' | grep -c .)}
  echo "os${T}$1${T}${count}${T}${sec}${T}$2${T}$3"
  printf '%s\n' "$rows" | awk -F'\t' -v m="$1" 'NF { print "pkg\t" $1 "\t" $2 "\t" $3 "\t" ($4 == 1 ? 1 : 0) "\t" m }' | head -n 200
}

check_apt() {
  # Private, compressed list cache (~85 MB) so stale system lists don't hide updates.
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-homelab/apt"
  fresh=0 apt_opts=""
  if mkdir -p "$cache/lists/partial" "$cache/archives/partial" 2>/dev/null; then
    private="-o Dir::State::Lists=$cache/lists -o Dir::Cache=$cache -o Dir::Cache::archives=$cache/archives
      -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= -o Acquire::GzipIndexes=true
      -o Acquire::CompressionTypes::Order::=gz -o Debug::NoLocking=1 -o APT::Sandbox::User=$(id -un)"
    # shellcheck disable=SC2086
    if timeout 180 apt-get $private -qq update >/dev/null 2>&1; then apt_opts=$private; fresh=1; fi
  fi
  age=0
  [ "$fresh" = 1 ] || age=$(mtime_age /var/lib/apt/periodic/update-success-stamp /var/cache/apt/pkgcache.bin /var/lib/apt/lists/partial)
  # Same set as `apt upgrade`. "Inst name [current] (new origin [arch])".
  # shellcheck disable=SC2086
  apt-get -s -o Debug::NoLocking=1 $apt_opts --with-new-pkgs upgrade 2>/dev/null \
    | sed -n 's/^Inst \([^ ]*\) \(\[\([^]]*\)\] \)\{0,1\}(\([^ ]*\) \(.*\)$/\1\t\4\t\3\t\5/p' \
    | awk -F'\t' '{ print $1 "\t" $2 "\t" $3 "\t" ($4 ~ /[Ss]ecurity/ ? 1 : 0) }' \
    | emit apt "$age" "$fresh"
}

check_rpm() {
  # dnf/yum refresh metadata into a per-user cache when not root.
  pm=$1
  out=$(timeout 300 "$pm" -q check-update 2>/dev/null); rc=$?
  fresh=1; [ "$rc" = 0 ] || [ "$rc" = 100 ] || fresh=0
  secnames=$(timeout 120 "$pm" -q updateinfo list --security --updates 2>/dev/null \
    | awk '{ print $NF }' | sed 's/-[^-]*-[^-]*$//' | sort -u | tr '\n' ' ')
  rpm -qa --qf '%{NAME}.%{ARCH}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null > "$tmpd/installed"
  printf '%s\n' "$out" | awk '/^(Obsoleting|Security:)/ { exit } NF == 3 && $1 ~ /\./ && $2 ~ /[0-9]/ { print $1 "\t" $2 }' \
    | awk -F'\t' -v sec=" $secnames " 'NR == FNR { cur[$1] = $2; next }
        { n = $1; sub(/\.[^.]*$/, "", n); print n "\t" $2 "\t" cur[$1] "\t" (index(sec, " " n " ") ? 1 : 0) }' "$tmpd/installed" - \
    | emit "$pm" "$( [ "$fresh" = 1 ] && echo 0 || mtime_age /var/cache/dnf /var/cache/yum )" "$fresh"
}

check_pacman() {
  # checkupdates (pacman-contrib) syncs into a temporary database, no root.
  if command -v checkupdates >/dev/null 2>&1; then
    out=$(timeout 180 checkupdates 2>/dev/null); rc=$?
    fresh=1; [ "$rc" = 0 ] || [ "$rc" = 2 ] || fresh=0
  else
    out=$(pacman -Qu 2>/dev/null); fresh=0
  fi
  age=0; [ "$fresh" = 1 ] || age=$(mtime_age /var/lib/pacman/sync/*.db)
  printf '%s\n' "$out" | awk 'NF >= 4 && $3 == "->" { print $1 "\t" $4 "\t" $2 "\t0" }' | emit pacman "$age" "$fresh"
}

check_zypper() {
  # zypper cannot refresh repositories without root: system metadata only.
  # Security fixes come as patches, not per package, so count those.
  patches=$(zypper --non-interactive --no-refresh -q list-patches --category security 2>/dev/null \
    | awk -F'|' 'NF > 2 && $0 ~ /security/' | grep -c .)
  zypper --non-interactive --no-refresh -q list-updates 2>/dev/null \
    | awk -F'|' 'NF >= 5 { for (i = 1; i <= NF; i++) gsub(/^ +| +$/, "", $i)
        if ($1 == "v") print $3 "\t" $5 "\t" $4 "\t0" }' \
    | SECURITY_COUNT=$patches emit zypper "$(mtime_age /var/cache/zypp/solv/*/solv /var/cache/zypp/raw)" 0
}

check_apk() {
  # --no-cache fetches fresh indexes into memory, no root needed.
  out=$(timeout 120 apk --no-cache version -l '<' 2>/dev/null) && fresh=1 || { out=$(apk version -l '<' 2>/dev/null); fresh=0; }
  printf '%s\n' "$out" | awk '$2 == "<" { full = $1; name = full; sub(/-[0-9][^-]*(-r[0-9]+)?$/, "", name)
        cur = substr(full, length(name) + 2); print name "\t" $3 "\t" cur "\t0" }' \
    | emit apk "$( [ "$fresh" = 1 ] && echo 0 || mtime_age /var/cache/apk /lib/apk/db/installed )" "$fresh"
}

check_xbps() {
  # -M syncs repository indexes in memory only.
  out=$(timeout 180 xbps-install -Mun 2>/dev/null) && fresh=1 || { out=$(xbps-install -un 2>/dev/null); fresh=0; }
  printf '%s\n' "$out" | awk '$2 == "update" { print $1 }' | while IFS= read -r pkgver; do
    name=${pkgver%-*}
    echo "${name}${T}${pkgver##*-}${T}$(xbps-query -p pkgver "$name" 2>/dev/null | sed 's/.*-//')${T}0"
  done | emit xbps "$( [ "$fresh" = 1 ] && echo 0 || mtime_age /var/db/xbps/https* )" "$fresh"
}

check_flatpak() {
  out=$(timeout 120 flatpak remote-ls --updates --columns=application,version 2>/dev/null) || return 0
  flatpak list --columns=application,version 2>/dev/null > "$tmpd/flatpaks"
  printf '%s\n' "$out" | awk -F'\t' 'NR == FNR { cur[$1] = $2; next } NF { print $1 "\t" ($2 != "" ? $2 : "latest") "\t" cur[$1] "\t0" }' \
    "$tmpd/flatpaks" - | emit flatpak 0 1
}

check_snap() {
  out=$(timeout 120 snap refresh --list 2>/dev/null) || return 0
  snap list 2>/dev/null | awk 'NR > 1 { print $1 "\t" $2 }' > "$tmpd/snaps"
  printf '%s\n' "$out" | awk 'NR == FNR { cur[$1] = $2; next } FNR > 1 && NF { print $1 "\t" $2 "\t" cur[$1] "\t0" }' \
    "$tmpd/snaps" - | emit snap 0 1
}

tmpd=$(mktemp -d)
if command -v apt-get >/dev/null 2>&1; then check_apt
elif command -v dnf >/dev/null 2>&1; then check_rpm dnf
elif command -v yum >/dev/null 2>&1; then check_rpm yum
elif command -v pacman >/dev/null 2>&1; then check_pacman
elif command -v zypper >/dev/null 2>&1; then check_zypper
elif command -v apk >/dev/null 2>&1; then check_apk
elif command -v xbps-install >/dev/null 2>&1; then check_xbps
fi
command -v flatpak >/dev/null 2>&1 && check_flatpak
command -v snap >/dev/null 2>&1 && check_snap
rm -rf "$tmpd"

# Reboot needed: Debian/Ubuntu flag file, RHEL-family needs-restarting, or a
# running kernel whose modules were removed by an upgrade (Arch, Void, …).
reboot=0
[ -e /var/run/reboot-required ] && reboot=1
if [ "$reboot" = 0 ] && command -v needs-restarting >/dev/null 2>&1; then
  needs-restarting -r >/dev/null 2>&1 || [ $? != 1 ] || reboot=1
fi
[ "$reboot" = 0 ] && [ -d /lib/modules ] && [ ! -d "/lib/modules/$(uname -r)" ] && [ ! -d "/usr/lib/modules/$(uname -r)" ] && reboot=1
# Distributions that keep versioned kernels in /boot (Debian, Fedora, …):
# a newer installed kernel than the running one means a reboot is pending.
if [ "$reboot" = 0 ]; then
  newest=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|^/boot/vmlinuz-||' | grep -v rescue | sort -V | tail -n 1)
  case $newest in
    [0-9]*) [ "$newest" != "$(uname -r)" ] && [ "$(printf '%s\n%s\n' "$newest" "$(uname -r)" | sort -V | tail -n 1)" = "$newest" ] && reboot=1 ;;
  esac
fi

sudo -n true >/dev/null 2>&1 && echo "sudo${T}1"
[ "$reboot" = 1 ] && echo "reboot${T}1"
# A package operation running right now (results may be in flux).
pgrep -x 'apt|apt-get|aptitude|dpkg|unattended-upgr|dnf|dnf5|yum|rpm|pacman|zypper|apk|xbps-install' >/dev/null 2>&1 && echo "busy${T}1"
exit 0
