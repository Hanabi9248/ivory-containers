#!/usr/bin/env bash
# Real complete modules under bash -e; database commands are boundary fixtures.
set -eo pipefail
source_root="${1:?usage: bash tests/readiness-errexit.sh SOURCE_ROOT}"
source_root="$(cd "$source_root" && pwd)"
: "${TMPDIR:?Main must provide private TMPDIR}"
private_tmp="$(cd "$TMPDIR" && pwd)"
work="$(mktemp -d "$private_tmp/readiness-errexit.XXXXXX")"
work="$(cd "$work" && pwd)"
case "$work" in
    "$private_tmp"/readiness-errexit.*) ;;
    *) echo 'FAIL: unsafe cleanup target' >&2; exit 1 ;;
esac
trap 'rm -rf -- "$work"' EXIT
# Existing production PGROOT command paths are unquoted: do not bundle that
# independent concern into these tests. Main can supply a short private TMPDIR.
case "$work" in
    *[[:space:]]*) echo 'SKIP: use a private TMPDIR without whitespace' >&2; exit 77 ;;
esac
mkdir -p "$work/pg/bin"

cat > "$work/probe-fixture.sh" <<'PROBE'
#!/usr/bin/env bash
set -e
name="${0##*/}"
count_file="$READY_CASE_DIR/$name.count"
count="$(< "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
printf '%s\n' "$@" >> "$READY_CASE_DIR/$name.args"
case "$name" in
    pg_isready) success_at="$READY_SERVER_SUCCEED_AT" ;;
    psql) success_at="$READY_QUERY_SUCCEED_AT" ;;
    *) exit 90 ;;
esac
if [ "$success_at" -gt 0 ] && [ "$count" -ge "$success_at" ]; then
    exit 0
fi
exit 2
PROBE
cp "$work/probe-fixture.sh" "$work/pg/bin/pg_isready"
cp "$work/probe-fixture.sh" "$work/pg/bin/psql"
chmod +x "$work/pg/bin/pg_isready" "$work/pg/bin/psql"

cat > "$work/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
# Invoked as an independent bash -e process, never as an if/|| condition here.
source "$1"
export PGROOT="$READY_PGROOT"
# Boundaries: no production /usr scan and no real backoff delay.
find() { printf '%s\n' "$READY_PGROOT"; }
sleep() { printf '%s\n' "$1" >> "$READY_CASE_DIR/sleeps"; }
"$2" postgres example.test 5432 postgres
printf '%s\n' survived > "$READY_CASE_DIR/survived"
DRIVER

run_case() {
    module="$1"
    fn="$2"
    label="$3"
    server_at="$4"
    query_at="$5"
    expected_status="$6"
    expected_server="$7"
    expected_query="$8"
    expected_sleeps="$9"
    export READY_CASE_DIR="$work/${module//\//-}-$fn-$label"
    export READY_PGROOT="$work/pg"
    export READY_SERVER_SUCCEED_AT="$server_at"
    export READY_QUERY_SUCCEED_AT="$query_at"
    mkdir -p "$READY_CASE_DIR"
    printf '0\n' > "$READY_CASE_DIR/pg_isready.count"
    printf '0\n' > "$READY_CASE_DIR/psql.count"
    : > "$READY_CASE_DIR/sleeps"
    # Capture failure in the parent only. The child still has active errexit,
    # and its helper invocation is not wrapped in an if, !, && or || list.
    set +e
    "$BASH" -e "$work/driver.sh" "$source_root/$module" "$fn" > "$READY_CASE_DIR/output" 2>&1
    status=$?
    set -e
    actual_server="$(< "$READY_CASE_DIR/pg_isready.count")"
    actual_query="$(< "$READY_CASE_DIR/psql.count")"
    actual_sleeps="$(paste -sd, "$READY_CASE_DIR/sleeps")"
    if [ "$status" -ne "$expected_status" ] ||
       [ "$actual_server" -ne "$expected_server" ] ||
       [ "$actual_query" -ne "$expected_query" ] ||
       [ "$actual_sleeps" != "$expected_sleeps" ]; then
        printf 'FAIL %s %s %s: status=%s server=%s query=%s sleeps=%s\n' "$module" "$fn" "$label" "$status" "$actual_server" "$actual_query" "$actual_sleeps" >&2
        cat "$READY_CASE_DIR/output" >&2
        return 1
    fi
    if [ "$expected_status" -eq 0 ]; then
        [ -f "$READY_CASE_DIR/survived" ] || return 1
    else
        [ ! -f "$READY_CASE_DIR/survived" ] || return 1
    fi
    printf 'PASS %s %s %s\n' "$module" "$fn" "$label"
}

failures=0
for module in bin/common/common_lib.sh bin/pgbackrest-restore/restore_common_lib.sh; do
    for fn in test_server test_query; do
        if [ "$fn" = test_server ]; then
            first_server=1; first_query=0
            second_server=2; second_query=0
            all_server=5; all_query=0
        else
            first_server=0; first_query=1
            second_server=0; second_query=2
            all_server=0; all_query=5
        fi
        if run_case "$module" "$fn" first-success 1 1 0 "$first_server" "$first_query" ''; then :; else failures=$((failures + 1)); fi
        if run_case "$module" "$fn" fail-once 2 2 0 "$second_server" "$second_query" 2; then :; else failures=$((failures + 1)); fi
        if run_case "$module" "$fn" always-fail 0 0 1 "$all_server" "$all_query" 2,4,8,16,32; then :; else failures=$((failures + 1)); fi
    done
    if run_case "$module" pgisready server-recovers 2 1 0 2 1 2; then :; else failures=$((failures + 1)); fi
    if run_case "$module" pgisready query-recovers 1 2 0 1 2 2; then :; else failures=$((failures + 1)); fi
done
[ "$failures" -eq 0 ]

