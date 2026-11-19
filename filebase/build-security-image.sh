#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mode=${1:-build}
case "$mode" in build|publish) ;; *) echo 'usage: filebase/build-security-image.sh [build|publish]' >&2; exit 2;; esac
patch_source=29e7c87140a9d88ffd3cf26ff07852bb81dc0a4a
controller_source=dfd0e62d63ecea42f4fbacf0b4aee14206b29264
release=${RELEASE:-v1.14.4-filebase.1}
registry=${REGISTRY:-ghcr.io/filebase}
base_image="$registry/ingress-nginx-base:v2.2.26-filebase.1"
controller_image="$registry/ingress-nginx-controller:$release"
mkdir -p .cache/filebase

# Fail closed if the independently reviewed stack or controller code changes.
git cat-file -e "$patch_source^{commit}"
git diff --exit-code "$controller_source" -- cmd internal pkg rootfs go.mod go.sum
git diff --exit-code "$patch_source" -- images/nginx/rootfs
python3 filebase/verify-patch-source.py

docker build --platform linux/amd64 --progress=plain \
  --label "dev.filebase.nginx-patches-source=$patch_source" \
  --tag "$base_image" images/nginx/rootfs
base_ref="$base_image"
if [[ "$mode" == publish ]]; then
  docker push "$base_image"
  base_ref=$(docker image inspect --format '{{index .RepoDigests 0}}' "$base_image")
  [[ "$base_ref" == "$registry/ingress-nginx-base@sha256:"* ]]
fi

export PKG=k8s.io/ingress-nginx ARCH=amd64 GOOS=linux
export COMMIT_SHA="$controller_source" REPO_INFO=https://github.com/filebase/ingress-nginx TAG="$release"
bash build/build.sh

# Never use the inherited NGINX_BASE: it does not include this patch stack.
docker build --platform linux/amd64 --progress=plain \
  --build-arg "BASE_IMAGE=$base_ref" --build-arg "VERSION=$release" \
  --build-arg TARGETARCH=amd64 --build-arg "COMMIT_SHA=$controller_source" \
  --build-arg "BUILD_ID=${GITHUB_RUN_ID:-local}" \
  --label org.opencontainers.image.source=https://github.com/filebase/ingress-nginx \
  --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
  --label "dev.filebase.controller-source=$controller_source" \
  --label "dev.filebase.nginx-patches-source=$patch_source" \
  --label "dev.filebase.nginx-base=$base_ref" \
  --tag "$controller_image" rootfs

docker run --rm --platform linux/amd64 "$controller_image" /nginx-ingress-controller --version
docker run --rm --platform linux/amd64 "$controller_image" nginx -V \
  > .cache/filebase/nginx-build.txt 2>&1
docker run --rm --platform linux/amd64 "$controller_image" sh -ec \
  'test "$(id -u)" = 101; test -x /wait-shutdown; test -f /usr/local/lib/lua/resty/redis.lua; test -d /etc/nginx/template'

image_ref=$(docker image inspect --format '{{.Id}}' "$controller_image")
if [[ "$mode" == publish ]]; then
  docker push "$controller_image"
  image_ref=$(docker image inspect --format '{{index .RepoDigests 0}}' "$controller_image")
  [[ "$image_ref" == "$registry/ingress-nginx-controller@sha256:"* ]]
fi
export FILEBASE_BASE_REF="$base_ref" FILEBASE_IMAGE_REF="$image_ref" FILEBASE_IMAGE_TAG="$controller_image"
python3 - <<'PY'
import hashlib,json,os,pathlib,subprocess
patches=sorted(pathlib.Path('images/nginx/rootfs/patches').glob('*.patch'))
manifest={
 'controller_source':'dfd0e62d63ecea42f4fbacf0b4aee14206b29264',
 'nginx_patch_source':'29e7c87140a9d88ffd3cf26ff07852bb81dc0a4a',
 'build_commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'base_image':os.environ['FILEBASE_BASE_REF'], 'image':os.environ['FILEBASE_IMAGE_REF'],
 'image_tag':os.environ['FILEBASE_IMAGE_TAG'],'platform':'linux/amd64','nginx_version':'1.27.1',
 'workflow_run':os.environ.get('GITHUB_RUN_ID'),
 'patches':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in patches},
}
pathlib.Path('.cache/filebase/build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({k:v for k,v in manifest.items() if k!='patches'},indent=2))
PY
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf 'Controller: `%s`\n\nNGINX base: `%s`\n' "$image_ref" "$base_ref" >> "$GITHUB_STEP_SUMMARY"
fi
