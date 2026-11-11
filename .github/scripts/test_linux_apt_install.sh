#!/usr/bin/env bash
# Regressions for bounded, signed apt install without Canonical DNS.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/dpkg-query" <<'MOCK'
#!/usr/bin/env bash
if [[ "${NN_TEST_ALREADY_INSTALLED:-0}" == 1 ]]; then
  printf '%s' 'install ok installed'
  exit 0
fi
if [[ -s "$NN_TEST_LOG.installed" ]]; then
  printf '%s' 'install ok installed'
  exit 0
fi
exit 1
MOCK

cat > "$tmp/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NN_TEST_LOG"
for arg in "$@"; do
  case "$arg" in
    Dir::Etc::sourcelist=*)
      cp "${arg#*=}" "$NN_TEST_SOURCES"
      ;;
  esac
done
if [[ "${NN_TEST_FAIL_MIRRORS:-0}" == 1 ]]; then
  exit 1
fi
if [[ "${NN_TEST_FAIL_FIRST:-0}" == 1 ]] &&
  grep -q 'mirrors.seas.harvard.edu' "$NN_TEST_SOURCES"; then
  exit 1
fi
if [[ " $* " == *' install '* ]]; then
  printf '%s' 'install ok installed' > "$NN_TEST_LOG.installed"
fi
MOCK

cat > "$tmp/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "-k" ]]; then
  shift 2
fi
shift
exec "$@"
MOCK

chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export NN_UBUNTU_CODENAME=noble
export NN_TEST_LOG="$tmp/apt.log"
rm -f "$NN_TEST_LOG.installed"
export NN_TEST_SOURCES="$tmp/sources.list"
export NN_TEST_ALREADY_INSTALLED=0

# The mocked sudo is deliberately not root; production signatures are
# verified by apt using the existing Ubuntu archive keyring.
test -f "$repo_root/.github/scripts/install_linux_prerequisites.sh" || {
  echo "Native dependency installer is missing." >&2
  exit 1
}
bash "$repo_root/.github/scripts/install_linux_prerequisites.sh" \
  poppler-utils || {
    echo "Signed mirror helper unexpectedly failed." >&2
    exit 1
  }
grep -q 'mirrors.seas.harvard.edu/ubuntu noble' "$NN_TEST_SOURCES"
grep -q 'signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg' \
  "$NN_TEST_SOURCES"
! grep -q 'azure.archive.ubuntu.com' "$NN_TEST_SOURCES"
grep -q 'poppler-utils' "$NN_TEST_LOG"

: > "$NN_TEST_LOG"
export NN_TEST_ALREADY_INSTALLED=1
bash "$repo_root/.github/scripts/install_linux_prerequisites.sh" \
  poppler-utils
test ! -s "$NN_TEST_LOG"

export NN_TEST_ALREADY_INSTALLED=0
rm -f "$NN_TEST_LOG.installed"
export NN_TEST_FAIL_MIRRORS=1
if bash "$repo_root/.github/scripts/install_linux_prerequisites.sh" \
  poppler-utils; then
  echo "Missing packages were incorrectly accepted." >&2
  exit 1
fi

unset NN_TEST_FAIL_MIRRORS
export NN_TEST_FAIL_FIRST=1
bash "$repo_root/.github/scripts/install_linux_prerequisites.sh" \
  poppler-utils
grep -q 'mirrors.edge.kernel.org/ubuntu noble' "$NN_TEST_SOURCES"

if bash "$repo_root/.github/scripts/install_linux_prerequisites.sh" \
  'poppler-utils;rm'; then
  echo "Unsafe package parameter was accepted." >&2
  exit 1
fi

echo "Native dependency mirror regressions passed."
