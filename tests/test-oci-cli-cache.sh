#!/usr/bin/env bash

#==============================================================================
# OCI CLI CACHE TEST
#==============================================================================

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"

cat > "$test_root/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "-m venv" ]]; then
  mkdir -p "$3/bin"
  cp "$0" "$3/bin/python"
  exit 0
fi
printf 'install\n' >> "$OCI_CLI_TEST_INSTALLS"
cat > "$(dirname "$0")/oci" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$OCI_CLI_VERSION"
EOF
chmod +x "$(dirname "$0")/oci"
PYTHON
chmod +x "$test_root/bin/python3"

export GITHUB_PATH="$test_root/github-path"
export HOME="$test_root/home"
export OCI_CLI_CACHE_ROOT="$test_root/cache"
export OCI_CLI_TEST_INSTALLS="$test_root/installs"
export OCI_CLI_VERSION=3.91.0
export PATH="$test_root/bin:$PATH"

bash "$repository_root/scripts/oci/install-cli.sh" >/dev/null
bash "$repository_root/scripts/oci/install-cli.sh" >/dev/null

if [[ "$(wc -l < "$OCI_CLI_TEST_INSTALLS" | tr -d ' ')" != "1" ]]; then
  printf 'OCI CLI installation was not reused from the persistent cache.\n' >&2
  exit 1
fi

printf 'oci_cli_cache=ready\n'