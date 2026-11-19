# Filebase NGINX security build

This image retains ingress-nginx controller v1.14.4 and rebuilds its NGINX
1.27.1 base using Chainguard's reviewed patches 00-58. It is a temporary bridge
for an existing deployment, not a new supported controller distribution.

Pinned inputs:

- Controller: `dfd0e62d63ecea42f4fbacf0b4aee14206b29264` (controller-v1.14.4).
- NGINX build and tests: `29e7c87140a9d88ffd3cf26ff07852bb81dc0a4a` from
  <https://github.com/chainguard-forks/ingress-nginx/pull/67>.
- Base image recipe: Alpine 3.23.3 pinned by digest in its Dockerfile.

The complete `images/nginx` tree is imported unchanged. The verifier compares
all files, including untracked files in a developer checkout, to the pinned
commit and checks that patches 00 through 58 are present exactly once. NGINX
continues to report 1.27.1; the image digest and provenance establish its patch
status. Every dynamic module is rebuilt against the patched headers.

## Build and verification

On a Linux amd64 machine with Docker, Python 3, and Go matching GOLANG_VERSION:

```sh
git fetch --no-tags https://github.com/chainguard-forks/ingress-nginx.git 29e7c87140a9d88ffd3cf26ff07852bb81dc0a4a
python3 filebase/verify-patch-source.py
make -C images/nginx test
go test ./internal/ingress/controller/template ./pkg/flags
bash filebase/build-security-image.sh build
```

After authenticating to GHCR, the `publish` mode pushes both images and builds
the controller against the base's registry digest. The default inherited
NGINX_BASE is deliberately ignored: it predates these fixes. Build output is
recorded in `.cache/filebase/build-manifest.json` and `nginx-build.txt`.

The Filebase GitHub Actions workflow runs the sanitizer suite before publishing
the candidate. Publication is not deployment. Application cache, Lua,
authentication, and billing regression suites must pass against the candidate
binary before its digest is selected for a production rollout.

## Deployment requirements

Keep `controller.config.use-http2: "false"` until every controller is patched.
Confirm successful reloads, HTTP/1.1 ALPN negotiation, and exit of old workers.
Retain the existing chart, custom template, Lua mounts, cache paths, and values
overlays. Update registry, image, tag, and digest together in Terraform.

For an OnDelete DaemonSet, replace pods one at a time, starting with a redundant
region. Require readiness, successful reload, representative route checks, and
no new worker failures before continuing. Restore HTTP/2 after all pods report
the approved digest. A rollback must retain the HTTP/2 mitigation.

No infrastructure state, credentials, or production configuration belongs in
this public source repository. Keep deployment evidence in the infrastructure
workspace. The separate kernel issue and controller migration remain outside
this image build.
