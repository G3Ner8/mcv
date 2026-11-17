# Commands

Everything the coordinator does goes through three scripts in the plugin's `bin/` folder, which
you can also run yourself: `mcv-herdr.sh` (workers), `mcv-status` (the record of questions and
answers) and `mcv-watch` (what wakes the coordinator). This page describes them for someone
running them by hand. To use mcv you do not need it: start with the [README](../README.md).

## Find the scripts

They are not on your `PATH`. Find the installed copy once:

```
find ~/.claude/plugins/cache/mcv -name mcv-herdr.sh
```

There is one folder per installed version (`.../mcv/mcv/<version>/bin/`); use the newest. Do not
use the copy under `~/.claude/plugins/marketplaces/`: that is the marketplace's checkout, not the
plugin Claude Code runs. Call it by its full path, either by asking Claude to run it or by typing it
after `!` in Claude Code. Below, `H` stands for that path.

```
H doctor                                     # herdr, its server, the integration, jq; prints mcv's version
H spawn brewly cart-fix ~/code/brewly/web fix/cart-total
                                             # new worktree on new branch fix/cart-total, idle Claude in it
H prompt brewly/cart-fix "The cart total ignores the oat-milk surcharge; fix it"
H read brewly/cart-fix                       # what the worker said
H agents                                     # every herdr agent and its state
H remove brewly/cart-fix                     # close it; keeps the branch if it holds work
```

Run `H` with no arguments for every command and option.

## Names

`brewly` is a **project** name and `cart-fix` a **task id**; you choose both. Use lowercase
letters, digits, `-` and `_`; the project starts with a letter; `<project>-<id>` is at most 32
characters.

Task state is kept outside every repository, in `~/.claude/mcv/<project>/tasks/<id>/`; set
`MCV_HOME` to keep it elsewhere (`spawn` passes it on to each worker; a relative path is taken
from the folder you run the helper in).

## spawn

`spawn <project> <id> <repo> <branch>` makes a worktree on a new branch and starts an idle Claude
in it.

- **The branch name** must not exist yet, locally, on a remote or as a tag. `main`, `master`,
  `develop` and a remote's own name (`origin`) are always refused, and so is a name one folder
  above or below an existing branch (`main/x`, or `feat` while `feat/x` exists). Names are
  compared ignoring letter case.
- **Where the branch starts.** `spawn` fetches first, then starts the branch from the default
  branch of `origin` (for example `origin/main`), or of the only remote when none is called
  `origin`, or from `--base <ref>` if you give one, so a worker never starts from a stale or
  unrelated checkout. A repository with no remote starts from its current HEAD; a `--base` that
  names a local branch is used as it is. If the default branch cannot be found (offline, several
  remotes and none called `origin`, nothing pushed yet), `spawn` stops and asks for `--base`
  rather than branch from a stale HEAD.
- **No upstream.** The new branch has none, so a plain `git push` from the worker cannot reach
  the base branch; the worker sets one when it first pushes its own branch.
- Two spawns in the same repository run one after the other.
- **`--existing`** puts a worker on a branch that is already on the remote instead, such as a
  merge request's branch that needs review fixes: the worktree starts at the remote's tip with
  that branch as its upstream, so the worker's plain `git push` updates the request, and its
  rules tell it not to open another one. It refuses the remote's default branch (and `main`,
  `master`, `develop`), a branch the remote does not have, one another worker is on, and a local
  branch of that name that is checked out or holds commits the remote lacks; a local branch that
  is only behind is moved up first. `remove` keeps the branch.
- **`--context <folder>` and `.worktreeinclude`:** see
  [What a worker has](../README.md#what-a-worker-has).
- **Claude's own flags** go after `--`; see [Permissions](../README.md#permissions) for the two
  that are refused.

The worktree goes under `~/.herdr/worktrees/`.

**When spawn fails while starting Claude,** the task is left in place. The usual cause is
Claude's folder trust dialog. Claude keeps that trust per repository, counting a worktree as its
repository's main checkout, so the dialog appears only until "Yes" has been picked once for the
repository: in a worker's pane, or by opening Claude in the repository itself. A trusted folder
above the repository does not count, so in Brewly each of `web`, `api` and `staff` asks once.
Its default answer is "No, exit": pick "Yes" in the worker's herdr pane, and `prompt` then works.
Otherwise run `remove` before using the same id again.

**Your shell's own questions.** `spawn` starts Claude by typing the `claude` command at the new
pane's shell prompt. Anything your shell asks first takes part of that command: oh-my-zsh's
update question did, and Claude never started. The error then ends with the pane's last lines.
For oh-my-zsh, set `zstyle ':omz:update' mode reminder` in `~/.zshrc`.

## prompt

`prompt <project>/<id> "<text>"` sends text to a worker and waits until it stops, up to 10
minutes by default (`--timeout <ms>`). It prints only the worker's new state; `read` shows what
the worker said.

- When Claude runs the helper for you, its Bash tool stops waiting after 2 minutes unless given
  a longer timeout, so for long work use `prompt --no-wait`, which returns as soon as the worker
  has started, and check back with `read`.
- **A busy worker is refused,** unless the text is an answer (`--answers q<n>`) or an order
  (`--order`): then nothing is sent, the text is kept as pending, to be sent when the worker
  stops, and the output says `queued`.
- **`--answers q<n>`** sends an answer and records it: as answered when it went in, as pending
  when the worker is busy. `--order` does the same for an order that answers nothing.
- **A worker that has not received mcv's rules is refused,** since it would never report its
  questions (the rules: [Git rules for workers](../README.md#git-rules-for-workers)). Usually it
  is still at the folder trust dialog: pick "Yes" there and prompt again. Otherwise its Claude
  did not load the mcv plugin, which happens when mcv is installed for one project only, or when
  you run the helper from a clone (pass `-- --plugin-dir <that clone>` to `spawn`); `remove` the
  worker and spawn it again.

## read and agents

`read <project>/<id>` shows the worker's screen, even after Claude has exited there; `prompt`
then says the worker is no longer running Claude. `agents` lists every herdr agent and its state:

| State | Meaning | `prompt` accepted? |
|---|---|---|
| `working` | busy | no |
| `blocked` | waiting at an approval or question dialog | no |
| `done` | stopped; its output not yet viewed | yes |
| `idle` | stopped | yes |
| `unknown` | herdr cannot tell | no |

## remove

`remove <project>/<id>` closes a worker and deletes its worktree.

- **It refuses** while the worker is working or waiting at a dialog, while the worktree has
  uncommitted or untracked files, and when git cannot read it.
- **Ignored files go with the worktree.** Files your `.gitignore` ignores (build output,
  dependencies, a local `.env`) are deleted.
- **The branch stays** as a local branch; push it first if you need it elsewhere. A branch that
  never moved from where it started, has no upstream and is on no remote held no work, so
  `remove` deletes it, and the same name can be used again.
- **It works on what is left.** It works after you have closed the worker's herdr workspace
  yourself, and for a task whose `spawn` was killed while herdr was still making its worktree: it
  removes that worktree and the unused branch (`leftover: true`), or you can simply spawn the
  task again. A `remove` that stopped half way can be run again and goes on from what is left.
- **Something still writing.** While something still writes into the worktree's folder (a dev
  server the worker left running) it refuses and says so: stop that, then run it again.
- **The record is kept.** Before deleting the task's state it copies the task's record to
  `~/.claude/mcv/<project>/history/` (see [What mcv writes](../README.md#what-mcv-writes)).

## Workers in herdr's sidebar

herdr shows each worker's workspace, labelled `⧉ <id> · <project>`, under a workspace for its
repository's main checkout, and opens that one if you do not have it open. The task comes first
because the sidebar cuts long labels, after about 12 characters on herdr 0.9.5, so the
coordinator keeps ids that short when it can. Which workspace herdr takes as the main checkout is
not always the coordinator's, and mcv cannot choose it; when you already have a workspace open on
the repository, workers appear under that one.

After the last worker of a repository, `remove` closes the workspace herdr opened for it, unless
you have started using it; one you opened yourself is never closed.

**Closing a repository's workspace in herdr closes the workers under it.**

## mcv-watch and mcv-status

Both sit next to `mcv-herdr.sh`. Run either with no arguments for its usage.

- `mcv-watch <project>` prints each question and stop as it happens, which is what the
  coordinator sees. `--resume` goes on where the last one stopped, without showing anything
  twice.
- `mcv-status --task <project>/<id> answered q<n> "<why>"` closes a question when nothing is sent
  (you answered in the worker's pane), and `amended` records a correction sent after an answer.
