#!/bin/sh
# For every module under modules/: `terraform init -backend=false`, then
# `terraform validate`, then `terraform test` if the module has *.tftest.hcl.
# Every module runs whatever an earlier one gives; exits 1 if any failed.
# Needs no credentials: nothing is planned against AWS (tests mock it).
#
# A module that declares `configuration_aliases` expects its caller to pass
# those providers, and validate fails without them ("Provider configuration
# not present"). So, as a caller would, this declares each alias, in a file
# the job writes and never commits. The block is empty: validate configures
# no provider.
set -u
cd "$(dirname "$0")/.."

rc=0
for d in modules/*/; do
  d=${d%/}
  echo "== $d"
  stub="$d/amber_ci_caller_providers.tf"
  rm -f "$stub"
  for a in $(cat "$d"/*.tf | tr -d ' \t\r\n' | grep -o 'configuration_aliases=\[[^]]*\]' | sed 's/^[^[]*\[//; s/\]$//' | tr ',' ' '); do
    printf 'provider "%s" {\n  alias = "%s"\n}\n' "${a%%.*}" "${a#*.}" >> "$stub"
    echo "(declared provider $a, as a caller passes it)"
  done
  if ! (cd "$d" && terraform init -backend=false -input=false && terraform validate); then
    rc=1
    continue
  fi
  if ls "$d"/*.tftest.hcl >/dev/null 2>&1; then
    (cd "$d" && terraform test) || rc=1
  fi
done
exit $rc
