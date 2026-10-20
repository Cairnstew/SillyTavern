---
name: nix-coverage
description: Use when auditing, extending, or reviewing the NixOS module that packages SillyTavern — services.sillytavern-nixos, modules/options.nix, the account/file seeders, or "is everything Nix-drivable". Finds gaps in the Nix wrapper against upstream's real config.yaml, CLI flags and SILLYTAVERN_* env vars, fixes them, and records the coverage map in COVERAGE.md.
---

# Nix coverage audit

The module claims that **everything** in SillyTavern can be set from Nix.
This skill is how that claim is checked, extended, and kept true. It exists
because the claim drifts: upstream adds a config key every release, the module
gains options, and nobody notices the gap until someone tries to set the new
key and finds it silently absent.

## What "covered" means

A configuration input is **covered** when a Nix user can set it and it has an
effect. Concretely, per surface:

| Surface | Covered when | Failure mode if not |
|---|---|---|
| `config.yaml` key | an option exists under `services.sillytavern-nixos.config.<key>` | key has no effect, silently |
| CLI flag | an option exists under `services.sillytavern-nixos.cli.<flag>` | argv outranks config.yaml, so a wrong Nix value loses |
| `SILLYTAVERN_*` env | `extraConfigEnv` escape hatch exists and docs say env beats config.yaml | env silently overrides the rendered config |
| per-account state | seedable via `files.byUser` | cannot be provisioned declaratively |

**Do not** treat "the option exists" as the end of it. An option that is
declared but not actually rendered into the config, or overridden by argv, is
not covered. `configYamlRoundTrip` and `guardsFire` (below) exist to catch that
class of lie.

## Run the audit first

```bash
python3 .opencode/skills/nix-coverage/scripts/audit.py
```

It derives ground truth from the upstream sources at the pinned version —
never from a hardcoded list — and diffs it against the module's real option
tree, which it gets from Nix itself via `lib.optionAttrSetToDocList`. Output
is a coverage percentage plus the specific uncovered keys.

`--json` for machine-readable, `--strict` to exit non-zero on findings (CI).

If it reports 100%, the `config.yaml` surface is genuinely complete. **That is
the current state** — see `COVERAGE.md`. Do not go hunting for config keys that
are not there. Look instead at:

- **`COVERAGE.md` §7 "Known improvements"** — the actionable list, each with a
  reproduction recipe. Start here; two entries are already-confirmed bugs.
- **`docs/ui-surface.md` §7 "Open questions for later"** — content-state
  questions (character cards, chats, `movingUI/`) rather than option coverage.

If the audit reports *less* than 100%, that is a real regression: fix the
option, not the audit. But see `RUN-LOG.md` — before adding an option, check
whether the gap is the parser's fault.

## The loop

Work gaps in this order. Each step is a checkpoint; do not skip ahead.

1. **Reproduce.** Before changing anything, show the gap is real. For a config
   key, evaluate the option tree and show the key has no option. For a runtime
   bug, run the server and show the wrong behaviour. A gap you cannot reproduce
   is a gap you will "fix" by guessing.
2. **Fix at the right layer.** Config keys → `modules/options.nix` (default
   MUST equal upstream's, or `configYamlRoundTrip` fails). Runtime wiring →
   `modules/config.nix` or `modules/services.nix`. Seeding → `scripts/`.
3. **Add a check that fails without the fix.** A check that cannot fail is
   worse than none — see `guardsFire`'s origin in `RUN-LOG.md`. Every new
   assertion gets a row in `guardsFire`; every new systemd directive gets a row
   in `hardeningPinned`; every reimplemented-upstream function gets a case in
   `libHelpers`.
4. **Live-test.** Evaluation proves the option exists; it does not prove the
   server honours it. Boot the server with the value set and observe the
   effect. This is required — see "Live testing" below.
5. **Record it.** Update `COVERAGE.md` in the same change. A gap fixed but not
   recorded will be re-found by the next agent, or worse, left in the exclusion
   list with no reason.

## Live testing

`nix flake check` evaluates; it does not run the server. Most of the failures
this module has actually had were invisible to evaluation — a unit that would
not start, a file seeded with the wrong mode, an option that rendered but was
overridden by argv.

Boot it:

```bash
nix build --impure --no-link --print-out-paths -f /tmp/live.nix
```

`/tmp/live.nix` builds the package plus a rendered config and seed spec into
one store path, so you can start the server by hand with a throwaway data root:

```nix
# /tmp/live.nix — reuse this shape; see docs for a full example
let
  f = builtins.getFlake "path:/home/seanc/Projects/SillyTavern";
  lib = f.inputs.nixpkgs.lib;
  pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; };
  cfg = (lib.nixosSystem { system = "x86_64-linux"; modules = [
    f.nixosModules.sillytavern
    { boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/null"; fsType = "tmpfs"; };
      system.stateVersion = "25.05";
      nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform;
      services.sillytavern-nixos = {
        enable = true;
        dataRoot = "/tmp/live/data";
        config.enableUserAccounts = true;
        users.me = { name = "Me"; passwordFile = pkgs.writeText "pw" "x"; };
        # the option under test goes here
      }; } ]; }).config;
  st = cfg.services.sillytavern-nixos;
in pkgs.runCommand "live" {} ''
  mkdir -p $out
  cp ${st.internal.renderedConfig} $out/config.yaml
  cp ${st.internal.seedSpec} $out/spec.json
  cp -r ${st.internal.packaged} $out/package
  cp ${/home/seanc/Projects/SillyTavern/scripts/st_seed_files.py} $out/seeder.py
  cp ${/home/seanc/Projects/SillyTavern/scripts/st_seed_users.py} $out/seeder-users.py
''
```

Then, against the built store path:

```bash
B=$(nix build --impure --no-link --print-out-paths -f /tmp/live.nix)
rm -rf /tmp/live/data && mkdir -p /tmp/live/data/me
python3 $B/seeder-users.py --data-root /tmp/live/data \
  --user 'handle=me,name=Me,admin=true,enabled=true,passwordFile=/tmp/live/pw'
python3 $B/seeder.py --data-root /tmp/live/data --spec $B/spec.json --policy missing
$B/package/bin/sillytavern --configPath=$B/config.yaml --dataRoot=/tmp/live/data &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:<port>/
```

Three things to check every time:

- **The server started at all.** A systemd unit that renders but will not start
  evaluates perfectly. This already happened once.
- **The EROFS on config.yaml is expected.** The config is a store path and is
  read-only by design. That error is the design working, not a bug.
- **Seeded files landed with the right content AND mode.** `stat -c '%a %n'`.

Always clean up the server afterwards — `kill` the PID, confirm the port is
closed.

## Rules

- **Never hardcode a surface.** The audit derives config keys from
  `default/config.yaml`, flags from `src/command-line.js`, and options from
  Nix. A second copy in the script goes stale silently, which is the exact
  failure this skill exists to prevent.
- **An option's default must equal upstream's**, unless you deliberately
  override it in `effectiveConfig` (`modules/config.nix`) with a comment saying
  why. `configYamlRoundTrip` byte-diffs the rendered document against upstream's.
- **Add an assertion only for configurations that fail SILENTLY.** If it already
  fails loudly, it does not belong in `modules/assertions.nix`. Every assertion
  needs a `guardsFire` row proving it fires.
- **Never seed user-authored content.** `chats/`, `assets/`, `user/` and
  backups are the user's own. Excluding them is correct, and excluding them is
  not a gap.
- **Some gaps need upstream, not Nix.** If the only way to set something is
  through a file served read-only out of the package, an option would be a
  lie. Record it in `COVERAGE.md` under *needs upstream*, do not fake it.
- **`//` replaces, it does not merge.** `{ a = <42 keys>; } // { a = { X = 1; } }`
  drops 41. This is a real past bug.

## Self-improvement

This skill is expected to get better every time it is used. After a run that
teaches you something, append to `RUN-LOG.md`:

- a **new trap** the audit or the workflow did not catch → add it here and to
  `CONTRIBUTING.md`, with the file:line evidence;
- a **false positive** in `audit.py` → fix the parser and record what the parser
  got wrong, so the next run does not re-introduce it;
- a **check that could not fail** → this is the most important class. Record it
  prominently.

If you find the audit is wrong in a way that makes it useless, fixing the audit
is the highest-priority work this skill has. A stale coverage map is worse than
no map.

## Files

| Path | What it is |
|---|---|
| `scripts/audit.py` | the mechanical audit |
| `COVERAGE.md` | the live map — what is covered, what is not, why |
| `RUN-LOG.md` | append-only lessons; read before changing the audit |
| `docs/ui-surface.md` | the hand-written UI/state map, and open items |
| `lib/tests.nix` | the checks; `libHelpers`, `guardsFire`, `hardeningPinned` |