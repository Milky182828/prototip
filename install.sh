#!/bin/sh
set -eu

NAME="ProtoTip"
TAG="1212"
RELEASE_PAGE="https://github.com/Milky182828/prototip/releases/tag/$TAG"
ARCHIVE_URL="https://github.com/Milky182828/prototip/releases/download/$TAG/ProtoTip-main.zip"
IMAGE="prototip:$TAG"

fail() {
  echo "$NAME: $*" >&2
  exit 1
}

[ "$(id -u)" = 0 ] || fail "запустите через sudo"
command -v curl >/dev/null 2>&1 || fail "не найден curl"

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl unzip gzip
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl unzip gzip
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates curl unzip gzip
  else
    fail "поддерживаются Ubuntu, Debian, Fedora/RHEL и Alpine"
  fi
}

command -v unzip >/dev/null 2>&1 || install_packages

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  curl -fsSL --proto '=https' --tlsv1.2 https://get.docker.com | sh
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now docker
fi

docker info >/dev/null 2>&1 || fail "Docker не запущен"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

curl -fL --proto '=https' --tlsv1.2 --retry 3 "$ARCHIVE_URL" -o "$tmp/ProtoTip-main.zip" || fail "архив недоступен: $RELEASE_PAGE"
unzip -q "$tmp/ProtoTip-main.zip" -d "$tmp/source" || fail "не удалось распаковать архив"

src=""
for dir in "$tmp/source" "$tmp/source"/*; do
  if [ -f "$dir/Dockerfile" ] && [ -f "$dir/installer/Cargo.toml" ]; then
    src=$dir
    break
  fi
done
[ -n "$src" ] || fail "в архиве не найден проект ProtoTip"

DOCKER_BUILDKIT=1 docker build --build-arg VERSION="$TAG" -t "$IMAGE" "$src"
docker save "$IMAGE" | gzip -1 >"$tmp/ProtoTip-image.tar.gz"
docker run --rm -v "$src/installer:/work" -w /work rust:1.89-bookworm cargo build --release
install -m 755 "$src/installer/target/release/prototip" /usr/local/bin/prototip

if [ -r /dev/tty ] && [ -w /dev/tty ]; then
  exec /usr/local/bin/prototip install --image-tar "$tmp/ProtoTip-image.tar.gz" "$@" </dev/tty
fi
exec /usr/local/bin/prototip install --image-tar "$tmp/ProtoTip-image.tar.gz" "$@"
