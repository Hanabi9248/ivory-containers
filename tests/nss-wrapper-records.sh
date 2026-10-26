#!/usr/bin/env bash
# Exercise the actual UID bootstrap and NSS-file generator with path isolation.
# This checks generated records, not libc/libnss_wrapper lookup or a container.
set -eo pipefail

if ! command -v envsubst >/dev/null 2>&1; then
    echo "SKIP: real gettext envsubst is required" >&2
    exit 77
fi
source_root="${1:?usage: bash tests/nss-wrapper-records.sh SOURCE_ROOT}"
source_root="$(cd "$source_root" && pwd)"
: "${TMPDIR:?Main must provide a private TMPDIR for this validation}"
private_tmp="$(cd "$TMPDIR" && pwd)"
work="$(mktemp -d "$private_tmp/nss-records.XXXXXX")"
work="$(cd "$work" && pwd)"
case "$work" in
    "$private_tmp"/nss-records.*) ;;
    *) echo 'FAIL: refusing cleanup outside private TMPDIR' >&2; exit 1 ;;
esac
nss_root="$work/nss_wrapper"
trap 'rm -rf -- "$work"' EXIT

mkdir -p "$work/bin"
# Fixture boundary: map only the three fixed /tmp/nss_wrapper path statements.
# All record detection, creation, edits and envsubst logic stays verbatim.
# No host /tmp/nss_wrapper directory or /etc file is created or modified.
mapped_paths=0
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        'mkdir -p /tmp/nss_wrapper')
            printf 'mkdir -p %q\n' "$nss_root"
            mapped_paths=$((mapped_paths + 1)) ;;
        'chmod g+rwx /tmp/nss_wrapper')
            printf 'chmod g+rwx %q\n' "$nss_root"
            mapped_paths=$((mapped_paths + 1)) ;;
        'NSS_WRAPPER_DIR="/tmp/nss_wrapper/${NSS_WRAPPER_SUBDIR}"')
            printf 'NSS_WRAPPER_DIR=%q/"${NSS_WRAPPER_SUBDIR}"\n' "$nss_root"
            mapped_paths=$((mapped_paths + 1)) ;;
        *) printf '%s\n' "$line" ;;
    esac
done < "$source_root/bin/common/nss_wrapper.sh" > "$work/bin/nss_wrapper.sh"
if [ "$mapped_paths" -ne 3 ]; then
    echo 'FAIL: production path layout changed; review fixture mapping' >&2
    exit 1
fi
# Reverse those exact path statements and compare bytes to ensure no predicate
# or other production logic was changed by this fixture adaptation.
mapped_mkdir="$(printf 'mkdir -p %q' "$nss_root")"
mapped_chmod="$(printf 'chmod g+rwx %q' "$nss_root")"
mapped_dir="$(printf 'NSS_WRAPPER_DIR=%q/"${NSS_WRAPPER_SUBDIR}"' "$nss_root")"
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        "$mapped_mkdir") printf '%s\n' 'mkdir -p /tmp/nss_wrapper' ;;
        "$mapped_chmod") printf '%s\n' 'chmod g+rwx /tmp/nss_wrapper' ;;
        "$mapped_dir") printf '%s\n' 'NSS_WRAPPER_DIR="/tmp/nss_wrapper/${NSS_WRAPPER_SUBDIR}"' ;;
        *) printf '%s\n' "$line" ;;
    esac
done < "$work/bin/nss_wrapper.sh" > "$work/unmapped.sh"
cmp "$source_root/bin/common/nss_wrapper.sh" "$work/unmapped.sh"
cp "$source_root/bin/common/uid_postgres_no_exec.sh" "$work/bin/"
# Boundary: do not LD_PRELOAD Linux NSS/SSL libraries into the test shell.
# Production nss_wrapper_env.sh is not under test; generated files are.
printf '%s\n' '# NSS preload deliberately not activated in this file-generation test.' > "$work/bin/nss_wrapper_env.sh"

run_case() (
    case_name="$1"
    passwd_uid="$2"
    group_uid="$3"
    export CRUNCHY_DIR="$work"
    export USER_NAME=postgres
    export HOME=/var/lib/pgsql
    export NSS_WRAPPER_SUBDIR="$case_name"
    case_dir="$nss_root/$NSS_WRAPPER_SUBDIR"
    mkdir -p "$case_dir"
    printf 'root:x:0:0:root:/root:/bin/bash\npostgres:x:%s:0:PostgreSQL Server:/var/lib/pgsql:/bin/bash\n' "$passwd_uid" > "$case_dir/passwd"
    printf 'root:x:0:\npostgres:x:%s:postgres\n' "$group_uid" > "$case_dir/group"
    cp "$case_dir/passwd" "$case_dir/passwd.before"
    cp "$case_dir/group" "$case_dir/group.before"

    # Boundary: emulate an arbitrary runtime UID independent of host privileges.
    # GID 0 matches the supported OpenShift model; group naming policy is unchanged.
    id() {
        case "$1" in
            -u) printf '%s\n' 1001 ;;
            -g) printf '%s\n' 0 ;;
            *) return 2 ;;
        esac
    }
    source "$work/bin/uid_postgres_no_exec.sh" || return 1

    awk -F: '$1 == "postgres" && $3 == 1001 && $4 == 0 { found++ } END { exit found != 1 }' "$case_dir/passwd" || {
        echo "FAIL $case_name: missing exact postgres UID 1001 passwd record" >&2
        return 1
    }
    awk -F: '$1 == "postgres" && $3 == 1001 { found++ } END { exit found != 1 }' "$case_dir/group" || {
        echo "FAIL $case_name: missing exact postgres GID 1001 group record" >&2
        return 1
    }
    if [ "$case_name" = exact-existing ]; then
        cmp "$case_dir/passwd.before" "$case_dir/passwd" || return 1
        cmp "$case_dir/group.before" "$case_dir/group" || return 1
    fi
    cp "$case_dir/passwd" "$case_dir/passwd.once"
    cp "$case_dir/group" "$case_dir/group.once"
    source "$work/bin/uid_postgres_no_exec.sh" || return 1
    cmp "$case_dir/passwd.once" "$case_dir/passwd" || return 1
    cmp "$case_dir/group.once" "$case_dir/group" || return 1
    printf 'PASS %s\n' "$case_name"
)

failures=0
for case_name in passwd-uid-prefix group-gid-prefix exact-existing; do
    case "$case_name" in
        passwd-uid-prefix) user_id=10010; group_id=1001 ;;
        group-gid-prefix) user_id=1001; group_id=10010 ;;
        exact-existing) user_id=1001; group_id=1001 ;;
    esac
    if run_case "$case_name" "$user_id" "$group_id"; then
        :
    else
        failures=$((failures + 1))
    fi
done
[ "$failures" -eq 0 ]

