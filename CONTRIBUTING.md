# Contributing to this fork

> **This fork is [SillyTavern](https://github.com/SillyTavern/SillyTavern) plus
> Nix packaging.** Changes to the JavaScript application belong upstream; changes
> to `modules/`, `lib/`, `pkgs/`, `flake.nix` and `docs/` belong here. See
> [Upstream work](#upstream-work) below.

Two largely separate bodies of code live in this repository, and a change
usually belongs to exactly one of them.

## Upstream work

The JavaScript application, its tests, its webpack build and its docs are
upstream SillyTavern's. Changes to any of those — anything under `src/`,
`public/`, `tests/`, `default/`, `server.js` — should be sent to
<https://github.com/SillyTavern/SillyTavern>, not here.

This fork exists to package that application for NixOS, and to make its whole
configuration surface declarable. If a packaging change needs a behaviour that
upstream does not have, ask upstream first rather than forking the file here:
a local edit to `src/` makes the next `git pull` conflict, and the package
builds from this repository's tree, so the two drift apart silently.

## Setting up the dev environment

1. Required software: git and node.
2. Recommended editor: Visual Studio Code.
3. You can also use GitHub Codespaces which sets up everything for you.

## Getting the code ready

1. Register a GitHub account.
2. Fork this repository under your account.
3. Clone the fork onto your machine.
4. Open the cloned repository in the code editor.
5. Create a git branch (recommended), review the [git book](https://git-scm.com/book/en/v2/Getting-Started-About-Version-Control) if you haven't.
6. Make your changes and test them locally.
7. Commit the changes and push the branch to the remote repo.
8. Go to GitHub, and open a pull request.

Target **`release`**, which is this repository's default branch and the branch
the package is built from — the same branch upstream uses for releases, so the
two stay mergeable. CI runs on every push.

## Contribution guidelines

### Maintain code quality

Our standards are pretty low, but make sure the code is not too ugly:

- Run VS Code's autoformat when you're done.
- Check with ESLint by running `npm run lint`, then fix the errors.
- Use common sense and follow existing naming conventions.

### Use the correct target branch

Create pull requests for the `release` branch, which is what this repository builds from and what CI tests. (Upstream targets `staging`; this fork does not carry that branch.)

You can still send a pull request for `release` in the following scenarios:

- Updating README.
- Updating GitHub Actions.
- Hotfixing a critical bug.

Project maintainers will test and can change your code before merging. To keep our workflow smooth, please ensure the following:

- The "Allow edits from maintainers" option is checked.
- Avoid force-pushing your branch once the PR is out of draft state.

### Make contributions small and testable

To make sure that your contribution remains testable and reviewable, try not to exceed a soft limit of **200 lines of code** (both additions and deletions) per pull request. If you have more to contribute, split it into multiple pull requests.

We can also consider creating a separate feature branch for more substantial changes, but please discuss it with the maintainers first. For example:

- Leave the main larger PR as a draft so it can be used to discuss the implementation.
- Split each group of functions or features into a ~200 line PR so it can be properly reviewed and merged to `release` or a feature branch.
- If there are large codependent changes that cannot be split, start with the most utilized dependencies and stub dependent functions.
- Each will be reviewed and tested one by one, merging into the feature branch as they're ready.
- Do not create all branches in advance, as subsequent changes made in previous commits as a result of test/review may create a lot of merge conflicts.

### Provide clear descriptions of your changes

Write at least somewhat meaningful PR descriptions and commit messages. There's no "right" way to do it, but the following may help with outlining a general structure:

- What is the reason for a change?
- What did you do to achieve this?
- How would a reviewer test the change?

### We (likely) don't speak your language

English is the primary language of communication in this project. Please use only English when writing commit messages, PR descriptions, comments and other text. This does not apply to contributions to localization files.

### Legal stuff

Mind the license. Your contributions will be licensed under the GNU Affero General Public License. If you don't know what that implies, consult your lawyer.

## Use of AI coding assistance tools ("Vibe Coding")

We do not prohibit nor encourage the use of AI tools for coding assistance to help you write code, documentation, etc. This includes specialized IDEs, plugins and add-ons, chat interfaces, etc. However, please keep in mind the following:

- No matter who (or what) wrote the code, you are responsible for it. Make sure to carefully review and test everything before committing, and be ready to discuss and fix any issues that may arise during the review.
- Maintainers can reject reviewing and accepting PRs of very low quality, i.e. if the time to fix the issues exceeds the time to write the code from scratch.
- Avoid common mistakes attributed to AI tools, such as: adding/removing unrelated comments, excessive logging, unawareness of the project context and conventions, etc.
- You are allowed, but not required, to trigger AI tools that are added to the project by maintainers (Gemini, Copilot, Codex). Keep in mind that any feedback (comments, suggestions) that these tools generate is not a call to action; make sure to properly assess it before applying.

## Further reading

1. [How to write UI extensions](https://docs.sillytavern.app/for-contributors/writing-extensions/)
2. [How to write server plugins](https://docs.sillytavern.app/for-contributors/server-plugins)

---

# Working on the Nix packaging

## The shape of the tree

| Path | What it is |
|---|---|
| `justfile` | the task runner — `just --list` for every recipe |
| `flake.nix` | flake outputs: modules, overlay, package, checks, devShell |
| `default.nix` | the **non-flake** entry point (`builtins.fetchTarball`) |
| `overlay.nix` | adds `pkgs.sillytavern` |
| `pkgs/sillytavern/` | the package, and the source filter |
| `modules/sillytavern.nix` | import order: `options` → `config` → `services` → `assertions` |
| `modules/options.nix` | the whole option surface |
| `modules/config.nix` | renders `config.yaml`, the secrets env file and the argv |
| `modules/services.nix` | the systemd unit |
| `modules/assertions.nix` | guards against configurations that fail silently |
| `modules/home.nix` | the Home Manager half |
| `lib/` | shared renderers, exported as `self.lib` |
| `lib/tests.nix` | the `checks.*` flake output |
| `scripts/st_seed_*.py` | activation-time seeding |
| `nix-tests/` | the Python suites (`tests/` is upstream's **JavaScript** suite) |

## Before you open a PR

Everything is driven by the `justfile` at the repo root. `just --list` shows
every recipe; each one is a command that has actually been run.

```bash
just ci                # what CI runs: lint, flake check, unit tests, JS tests
just test              # the seeder suites (95+ tests)
just test-live         # build a server, boot it, assert over HTTP
just test-home         # modules/home.nix — needs network
just check             # every flake check
just audit             # the config-surface coverage audit
```

The raw commands, if you would rather not use `just`:

```bash
nix flake check                     # every check; this is what CI runs
python3 -m pytest nix-tests/        # the seeder suites (95+ tests)
./nix-tests/home-eval.sh            # modules/home.nix — needs network
```

`nix flake check` currently needs network for one check,
`configYamlRoundTrip`, which installs the `yaml` npm package. Behind a
TLS-intercepting proxy it fails with `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`; that
is environmental, and every other check is unaffected. Use `--no-build` for a
pure evaluation pass.

### The dev shell

`nix develop` gives you node, python + pytest, the Nix linters, shellcheck and
`just` itself. `just develop '<cmd>'` runs a command inside it
non-interactively, which is how the recipes reach their tools:

```bash
just develop "pytest nix-tests/"     # a command in the dev shell
just shell                            # the dev shell, interactively
just env                              # what is in it
```

Two things are deliberately NOT in the dev shell:

- **eslint.** nixpkgs ships eslint 10, which refuses to read this repo's
  `.eslintrc.cjs` — it wants `eslint.config.*`. The repo pins eslint 8 in
  `package.json`, so `just lint` runs the local `node_modules/.bin/eslint`.
  Run `just npm-ci` first.
- **a Nix formatter.** `nix flake check` runs the formatter check, and this
  project has no `formatter` output on purpose: every candidate formatter
  would rewrite the whole tree. `just fmt` exists and uses alejandra, but it
  is opt-in and never a gate.

## Adding an option

1. Declare it in `modules/options.nix`, under `services.sillytavern-nixos`.
2. If it maps to a `config.yaml` key, put it under the `config` submodule and
   give it a default **equal to upstream's** — `configYamlRoundTrip` byte-diffs
   the rendered document against `default/config.yaml`, and any divergence has
   to be a deliberate entry in that check's `overrides.json`.
3. If it needs a *different* default under systemd, override it in
   `effectiveConfig` in `modules/config.nix` rather than changing the option's
   default, and say why in a comment.
4. Add an assertion if the configuration can be **silently wrong**. If it
   already fails loudly, it does not belong in `assertions.nix`.
5. Add a row to the `guardsFire` table in `lib/tests.nix` if you added a guard,
   and pin any new systemd directive in `hardeningPinned`.

## Traps this codebase has already paid for

Each of these was a real bug. They are listed because they are all easy to
reintroduce.

- **`//` replaces, it does not merge.** `{ a = 1; } // { a = 2; }` is fine, but
  `{ serviceConfig = <42 directives>; } // { serviceConfig = { X = 1; }; }`
  deletes the other 41. This is how `systemdOverrides` silently produced a unit
  that could not start.
- **`lib.mapAttrs` calls `f name value`.** `lib.mapAttrs lib.attrNames m` passes
  the attribute *name* to an arity-1 function. Use `lib.attrValues (lib.mapAttrs
  lib.attrNames m)`.
- **`lib.optional cond [ "x" ]` double-wraps.** It already wraps: use
  `lib.optional cond "x"`.
- **`lib.concatLists` wants lists, not attrsets.** `lib.attrValues someMap` is a
  list of *attrsets*.
- **systemd directive names are case-sensitive and NixOS renders them
  verbatim.** `memoryMax` is not `MemoryMax`; the first is an unknown directive
  systemd silently ignores. That is what `hardware` exists to translate.
- **A Nix string is evaluated in the caller's scope.** In a non-recursive
  attribute set, `url = …; cmd = "''${url}/x"` fails with `undefined variable`.
- **Backticks in a `shellHook` are command substitution.** `echo "run
  \`just lint\` first"` EXECUTES `just lint`. If that recipe calls
  `nix develop`, the dev shell runs the shellHook, which runs the recipe,
  which enters the dev shell — forever. The symptom is a `nix develop` that
  never returns and a process tree that grows one level per second. Use
  single quotes in prose, and read the shellHook as shell, not as English.
- **A `path:` flake captures the working directory as it is on disk**, including
  untracked files — so a `result` symlink or a nested `node_modules/` ends up
  in the package. A `git+file:` flake captures the git snapshot instead. The
  source filter only covers the flake's own `source`, so `installPhase` has to
  clean up after itself. See `pkgs/sillytavern/default.nix`.

## Commit and branch

The application is developed on `release`, matching upstream's release branch.
Fixes to the packaging land there too. CI runs on every push.
