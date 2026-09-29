#!/usr/bin/env bash

#==============================================================================
# OCI CLI INSTALLATION
#==============================================================================

set -euo pipefail

: "${OCI_CLI_VERSION:?OCI_CLI_VERSION is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"
: "${HOME:?HOME is required}"

cache_root="${OCI_CLI_CACHE_ROOT:-$HOME/.cache/bharathcloudops/oci-cli}"
install_directory="$cache_root/$OCI_CLI_VERSION"
if [[ -x "$install_directory/bin/oci" ]] &&
	[[ "$("$install_directory/bin/oci" --version 2>&1)" == "$OCI_CLI_VERSION" ]]; then
	printf '%s\n' "$install_directory/bin" >> "$GITHUB_PATH"
	"$install_directory/bin/oci" --version
	exit 0
fi

mkdir -p "$cache_root"
staging_directory=$(mktemp -d "$cache_root/.${OCI_CLI_VERSION}.XXXXXX")
trap 'rm -rf "$staging_directory"' EXIT
python3 -m venv "$staging_directory"
"$staging_directory/bin/python" -m pip install --disable-pip-version-check --quiet "oci-cli==$OCI_CLI_VERSION"
[[ "$("$staging_directory/bin/oci" --version 2>&1)" == "$OCI_CLI_VERSION" ]]
rm -rf "$install_directory"
mv "$staging_directory" "$install_directory"
trap - EXIT
printf '%s\n' "$install_directory/bin" >> "$GITHUB_PATH"
"$install_directory/bin/oci" --version