#!/usr/bin/env bash
# docker.sh [--rebuild] [test-file…] — run the stub tests (run.sh, same
# arguments) in an ubuntu:24.04 container, close to the CI runner. For a
# developer machine; CI and the pod run run.sh directly.
#
# Environment workaround: on a macOS host whose endpoint security agent
# authorizes every exec, one process start costs ~100 ms and the exec-bound
# suite takes hours (#182). The defect is on the host, and its real fix is
# there (an exclusion for the cg-test.* temp dirs, or a faster agent). In the
# container's VM the execs do not reach that agent. The container also removes
# the host's own git config (gpgsign), version-manager shims and jq version.
# Delete this script when the host runs the suite at CI speed again.
#
# The image is built once and tagged with the hash of its Dockerfile, so a
# change to the Dockerfile builds a new one; --rebuild forces a fresh build.
# The checkout's files (tracked, plus untracked files git does not ignore) are
# copied into the container: the run never writes to the host checkout.
# CG_TEST_JOBS passes through.
set -u
CALLER_DIR="$(pwd)"
cd "$(dirname "$0")" || exit 1
CHECKOUT="$(cd ../.. && pwd)"

REBUILD=0
[ "${1:-}" = "--rebuild" ] && { REBUILD=1; shift; }

command -v docker >/dev/null 2>&1 \
  || { echo "TESTS FAILED: docker is not installed"; exit 1; }
docker info >/dev/null 2>&1 \
  || { echo "TESTS FAILED: the docker daemon does not answer (start Docker / Rancher Desktop)"; exit 1; }

# A path argument becomes a path inside the container's copy of the checkout.
ARGS=""
for a in "$@"; do
  case "$a" in (*[[:space:]]*) echo "TESTS FAILED: test file path has whitespace: $a"; exit 1;; esac
  case "$a" in
    (*/*) p="$a"; case "$p" in (/*) ;; (*) p="$CALLER_DIR/$a";; esac
          [ -f "$p" ] || { echo "TESTS FAILED: no such test file: $a"; exit 1; }
          p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
          case "$p" in
            ("$CHECKOUT"/*) ARGS="$ARGS /home/tester/cg/${p#"$CHECKOUT"/}";;
            (*) echo "TESTS FAILED: test file is outside the checkout: $a"; exit 1;;
          esac;;
    (*) ARGS="$ARGS $a";;
  esac
done

# procps: ps for run.sh's lock. A non-root user: as root, the unwritable-dir
# cases of the precheck tests can write the dir and fail.
DOCKERFILE='FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git jq curl ca-certificates procps \
 && rm -rf /var/lib/apt/lists/*
RUN useradd -m tester
USER tester
WORKDIR /home/tester'
IMAGE="cg-tests:$(printf '%s' "$DOCKERFILE" | git hash-object --stdin | cut -c1-12)"

if [ "$REBUILD" -eq 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo ".. building $IMAGE" >&2
  printf '%s\n' "$DOCKERFILE" | docker build -q -t "$IMAGE" - >/dev/null \
    || { echo "TESTS FAILED: docker build of $IMAGE failed"; exit 1; }
fi

# COPYFILE_DISABLE: macOS tar would add ._* metadata files to the archive
git -C "$CHECKOUT" ls-files -z --cached --others --exclude-standard \
  | (cd "$CHECKOUT" && COPYFILE_DISABLE=1 tar -c --null -T - -f -) \
  | docker run --rm -i -e CG_TEST_JOBS="${CG_TEST_JOBS:-}" "$IMAGE" bash -c '
      mkdir cg && tar -x -f - -C cg 2>/dev/null || { echo "TESTS FAILED: copy into the container failed"; exit 1; }
      exec bash cg/scripts/tests/run.sh "$@"' run.sh $ARGS
