#!/usr/bin/env bash
#
# Run the standalone Swift regression scripts without failing fast. Pass one or
# more paths to select a subset, or --list to print the discovered test set.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIST_ONLY=0
declare -a TEST_FILES=()

while (($#)); do
    case "$1" in
        --list)
            LIST_ONLY=1
            ;;
        --)
            shift
            TEST_FILES+=("$@")
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
        *)
            TEST_FILES+=("$1")
            ;;
    esac
    shift
done

if ((${#TEST_FILES[@]} == 0)); then
    while IFS= read -r path; do
        TEST_FILES+=("$path")
    done < <(find "${REPO_ROOT}/scripts/tests" -maxdepth 1 -type f -name 'test_*.swift' | LC_ALL=C sort)
fi

if ((${#TEST_FILES[@]} == 0)); then
    echo "No standalone Swift tests found." >&2
    exit 1
fi

if ((LIST_ONLY)); then
    printf '%s\n' "${TEST_FILES[@]}"
    exit 0
fi

if [[ -n "${DAYPAGE_SWIFT_BIN:-}" ]]; then
    SWIFT_COMMAND=("${DAYPAGE_SWIFT_BIN}")
elif command -v xcrun >/dev/null 2>&1; then
    SWIFT_COMMAND=(xcrun swift)
elif command -v swift >/dev/null 2>&1; then
    SWIFT_COMMAND=(swift)
else
    echo "Neither xcrun nor swift is available." >&2
    exit 127
fi

overall=0
for file in "${TEST_FILES[@]}"; do
    if [[ "${file}" != /* ]]; then
        file="${REPO_ROOT}/${file}"
    fi
    echo "::group::Standalone Swift test: ${file#${REPO_ROOT}/}"
    if "${SWIFT_COMMAND[@]}" "${file}"; then
        echo "PASS: ${file#${REPO_ROOT}/}"
    else
        status=$?
        echo "FAIL: ${file#${REPO_ROOT}/} (exit ${status})" >&2
        overall=1
    fi
    echo "::endgroup::"
done

exit "${overall}"
