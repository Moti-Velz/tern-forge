#!/bin/bash
# Run inside an operation terminal: the backend and its hooks inherit this PTY.
set -u

if [ "$#" -ne 8 ]; then
    printf 'Usage: worktree-operation.sh MODE BACKEND TOOL REPOSITORY TARGET OPTION RECEIPT HOOK\n' >&2
    exit 64
fi

mode=$1
backend=$2   # worktrunk, orca or git
tool=$3      # wt or Orca's CLI; empty for git
repo=$4
target=$5    # create: the new branch; remove: the worktree path
option=$6    # create: the base branch; remove: the worktree's branch
receipt=$7
hook=$8      # git only: orca.yaml's setup (create) or archive (remove) script
case "$mode" in
    create) label='Worktree creation' ;;
    remove) label='Worktree removal' ;;
    *) printf 'Unknown operation: %s\n' "$mode" >&2; exit 64 ;;
esac
case "$backend" in
    worktrunk|orca) [ -n "$tool" ] || { printf 'No executable given for %s.\n' "$backend" >&2; exit 64; } ;;
    git) ;;
    *) printf 'Unknown backend: %s\n' "$backend" >&2; exit 64 ;;
esac
recorded=0
receipt_tmp=''

record_status() {
    local status=$1
    if [ "$recorded" -eq 1 ]; then
        return
    fi
    if [ -z "$receipt_tmp" ]; then
        receipt_tmp=$(/usr/bin/mktemp "${receipt}.tmp.XXXXXX") || {
            printf 'Cannot create completion receipt at %s (command exit %s).\n' "$receipt" "$status" >&2
            return 1
        }
    fi
    if printf '%s\n' "$status" > "$receipt_tmp" && /bin/mv -f "$receipt_tmp" "$receipt"; then
        recorded=1
        receipt_tmp=''
    else
        printf 'Cannot publish completion receipt at %s (command exit %s).\n' "$receipt" "$status" >&2
        return 1
    fi
}

on_exit() {
    local status=$?
    trap - EXIT
    if [ "$recorded" -eq 0 ]; then
        record_status "$status"
        printf '\n%s command completed; review output above\n' "$label"
        printf 'Command exit status: %s\n' "$status"
    fi
    if [ -n "$receipt_tmp" ]; then
        /bin/rm -f "$receipt_tmp"
    fi
    # Only after the receipt: Forge treats a missing PID file plus a missing
    # receipt as a helper that never started.
    /bin/rm -f "${receipt}.pid"
    exit "$status"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Check receipt writability before creating anything. mktemp uses mode 0600.
receipt_tmp=$(/usr/bin/mktemp "${receipt}.tmp.XXXXXX") || exit 73
# Forge checks this PID before treating a vanished terminal as a failure.
printf '%s\n' "$$" > "${receipt}.pid" || exit 73

# orca.yaml's contract, as Orca's hook runner does it: /bin/bash from the
# worktree root with ORCA_WORKTREE_PATH, ORCA_ROOT_PATH and ORCA_WORKSPACE_NAME
# set; the archive hook gets 120 seconds.
run_orca_hook() {
    local name=$1 worktree=$2
    [ -n "$hook" ] || return 0
    printf 'Running the orca.yaml %s script in %s\n\n' "$name" "$worktree"
    if [ "$name" = archive ] && command -v timeout >/dev/null 2>&1; then
        (cd "$worktree" && ORCA_WORKTREE_PATH="$worktree" ORCA_ROOT_PATH="$repo" ORCA_WORKSPACE_NAME="${worktree##*/}" \
            timeout 120 /bin/bash -c "$hook")
    else
        (cd "$worktree" && ORCA_WORKTREE_PATH="$worktree" ORCA_ROOT_PATH="$repo" ORCA_WORKSPACE_NAME="${worktree##*/}" \
            /bin/bash -c "$hook")
    fi
    local status=$?
    if [ "$status" -ne 0 ]; then
        printf '\nThe orca.yaml %s script failed (exit %s).\n' "$name" "$status" >&2
    fi
    return "$status"
}

create_worktree() {
    case "$backend" in
        worktrunk)
            "$tool" -C "$repo" switch --create --base "$option" --no-cd "$target"
            ;;
        orca)
            # Orca owns the path and branch naming; its JSON answer names the
            # worktree it made, which Forge reads beside the receipt.
            "$tool" worktree create --repo "path:$repo" --name "$target" --base-branch "$option" --no-parent --json \
                > "${receipt}.result"
            local status=$?
            /bin/cat "${receipt}.result"
            return "$status"
            ;;
        git)
            # Beside the primary checkout, as Worktrunk's default template does.
            local path="${repo%/}.${target//\//-}"
            if [ -e "$path" ]; then
                printf 'Refusing creation: %s already exists.\n' "$path" >&2
                return 1
            fi
            git -C "$repo" worktree add -b "$target" -- "$path" "$option" || return
            run_orca_hook setup "$path"
            ;;
    esac
}

remove_worktree() {
    # Recheck identity and cleanliness immediately before handing off.
    # Use an absolute path, not a branch shortcut that could target another tree.
    local root common target_common git_dir branch changes
    root=$(git -C "$target" rev-parse --show-toplevel) || return 1
    common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir) || return 1
    target_common=$(git -C "$target" rev-parse --path-format=absolute --git-common-dir) || return 1
    git_dir=$(git -C "$target" rev-parse --path-format=absolute --git-dir) || return 1
    if [ "$root" != "$target" ] || [ "$target_common" != "$common" ] || [ "$git_dir" = "$common" ]; then
        printf 'Refusing removal: target is not a linked worktree of this project.\n' >&2
        return 1
    fi
    branch=$(git -C "$target" symbolic-ref --quiet --short HEAD)
    if [ "$?" -gt 1 ] || [ "$branch" != "$option" ]; then
        printf 'Refusing removal: the worktree branch changed after confirmation.\n' >&2
        return 1
    fi
    changes=$(git -C "$target" status --porcelain=v1 --untracked-files=normal) || return 1
    if [ -n "$changes" ]; then
        printf 'Refusing removal: worktree has uncommitted or untracked files.\n' >&2
        return 1
    fi
    local status
    case "$backend" in
        worktrunk)
            "$tool" -C "$repo" remove --foreground --no-delete-branch -- "$target"
            status=$?
            ;;
        orca)
            # As archiving in Orca's app does: run orca.yaml's archive hook, and
            # let a failed hook stop the removal.
            "$tool" worktree rm --worktree "path:$target" --run-hooks --json
            status=$?
            ;;
        git)
            # A failed archive script stops the removal, as it does in Orca.
            run_orca_hook archive "$target" || return
            git -C "$repo" worktree remove -- "$target"
            status=$?
            ;;
    esac
    if [ "$status" -eq 0 ] && [ -e "$target" ]; then
        printf 'Removal returned success but the worktree path still exists.\n' >&2
        return 1
    fi
    return "$status"
}

# No pipeline, backgrounding, --yes or --no-hooks: project/user hooks see the
# original terminal and retain approval prompts.
if [ "$mode" = create ]; then
    create_worktree
else
    remove_worktree
fi
status=$?
record_status "$status"
printf '\n%s command completed; review output above\n' "$label"
printf 'Command exit status: %s\n' "$status"

# The controller can consume the receipt now; leave hook output on screen.
if [ -t 0 ]; then
    printf '\nPress Enter when you have finished reviewing this output. '
    IFS= read -r _ || :
fi
exit "$status"
