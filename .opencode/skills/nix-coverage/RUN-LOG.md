# RUN LOG — append-only

Lessons from running the `nix-coverage` skill. **Append only.** Add a dated
entry at the bottom after each run that teaches you something. Do not edit or
delete earlier entries — the value is in the accumulation, and in being able to
see when a trap was learned the hard way.

Read this before changing `scripts/audit.py` or the checks it leans on.

---

## 2026-10-19 — building the audit; three traps hit first-hand

These were all discovered by running the thing, not by reading it.

### A check that is described but does not exist is worse than no check

`lib/default.nix` carried a comment asserting that "`libHelpers` in
`lib/tests.nix` pins the mapping so a 'harmless' fix to it cannot slip
through." `libHelpers` did not exist. `keyToEnv` had shipped untested under a
comment promising it was tested.

The mapping was in fact correct — verified by hand against Node for six keys —
which is exactly why this is dangerous. A false guarantee is worse than an
acknowledged gap: it stops anyone from checking.

**Rule:** a check named in a comment must exist in `checks`, and must have been
mutation-tested. `libHelpers` now exists (134 cases, generated from
`config.yaml`), and catches a camelCase "cleanup" by name — it failed on
`ENABLECORSPROXY`, `DISABLECSRFPROTECTION` and `PERFORMANCE_MEMORYCACHECAPACITY`.

### Nix cannot run Nix inside a build sandbox

The first design for `libHelpers` had the check shell out to `nix eval` (then
`nix-instantiate`) from inside a `runCommand`. Both fail identically:

```
error: creating directory "/nix/var/nix/profiles": Permission denied
```

The sandbox has no writable profile dir and no daemon. `nix-instantiate
--eval` sounds like it avoids the daemon, but it writes the same profile.

**Rule:** evaluate Nix at **eval time** on the host, pass the result into the
derivation as JSON, and let the build do only the non-Nix half. The Nix side is
still the shipped library — `lib/tests.nix` imports the real `lib/default.nix` —
it is just evaluated in the only place Nix can run.

Two smaller traps from the same exercise:

- `builtins.split` takes a **list of separators**. `builtins.split "\n" text`
  splits on the newline *character* and yields empty strings between lines,
  which then get fed to `builtins.match` as if they were strings. Use
  `lib.splitString`.
- `builtins.match` returns `null` on no-match here, but the empty-list idiom
  `!= [ ]` also "works" — pick one and be consistent, because mixing them
  produces `expected a string but found a list: [ ]`.

### `//` replaced `systemdOverrides.serviceConfig` — again, in the new code

Writing the *checks* for `systemdOverrides`, I wrote the test rows as
`auth // { config.x = …; }`. That silently dropped `auth`, so all 12 `guardsFire`
rows went **dead** — and a table of dead rows looks exactly like a table of
passing rows. Caught only because `guardsFire` counts non-empty rows and the
count came back zero.

**Rule:** when writing a check, confirm it can FAIL. Break the thing on purpose
and watch the check go red by name. A check never seen red is untested.

### Auditing the auditor: the matcher was too loose

First version of the coverage matcher asked "does any option path END with this
key?" `cli.port` ends with `port`, so it "covered" `config.port`. Mutation test
— rename `config.port` to `config.portGONE` — and the audit still said 100%.

Fixed by comparing the path **below `config.`** only, so a sibling subtree
cannot stand in for it. Mutation now correctly reports 99.1% and names `port`.

**Lesson that matters more than the fix:** the first run of a coverage audit is
evidence the audit is broken, not evidence the code is clean. The number looked
like a pass *because* the check could not fail. Mutation-test the audit itself
before believing it.

### And the parser had a real bug the loose matcher was hiding

Tightening the matcher made 3 phantom `dimensions.*` gaps appear. Not phantom:
`thumbnails.dimensions: { 'bg': …, 'avatar': …, 'persona': … }` is an **inline
flow map** on one line, and a naive line parser sees one leaf called
`dimensions`, dropping every child — and, on the first fix attempt, dropping the
`thumbnails` ancestor too, producing `dimensions.bg.avatar.persona`.

Two fixes, both in `scripts/audit.py`:
- `_parse_flow` expands an inline `{…}` map into pseudo-lines.
- the parser stack stores the **full path** per entry, not a bare key name,
  because when a sibling is popped its parent is already gone and rebuilding
  the path chains siblings together.

**Rule:** when a coverage tool reports a gap, check whether the tool is right
*before* adding an option. A gap that disappears when you look at it is the
tool's bug.

### `lib.optionAttrSetToDocList`, not hand-rolled recursion

Every hand-rolled walk of `system.options` failed: the tree's leaves are option
declarations but intermediate nodes also hold lambdas and paths, so recursing
into every attrset walks off the end (`expected a list but found a function`).
nixpkgs already ships the supported helper. Use it.

Also note `lib.take`, not `builtins.take` — the latter does not exist.

### Audit result at time of writing

`config.yaml` 109/109 (100%), CLI 31/31, 259 options, 0 findings. That is the
honest current state: **the configurable surface really is complete.** The
remaining work is quality and open decisions, listed in `COVERAGE.md` §7 — not
missing options.

---

## 2026-10-19 — cold-run test of the skill; two real module bugs found

The skill was tested by a subagent with no prior context. It found a blocking
discovery bug, three defects in the audit, two stale doc claims, and **two real
module bugs**. All fixed.

### The skill was not discoverable — restart required

The subagent's `Skill` tool returned "nix-coverage not found". The skill lives
at `.opencode/skills/nix-coverage/SKILL.md`, which is the documented project
path. The cause: opencode loads config once at startup and does not hot-reload.
The subagent inherited the parent session's skill registry, rendered before the
skill existed.

**Rule:** after creating or editing a skill, the user must quit and restart
opencode. A skill created mid-session is invisible until then.

### The audit had no CLI coverage check

`audit.py` extracted CLI flags from `src/command-line.js` and printed
"31 declared upstream" — but never compared them to `cli.*` options. The
`COVERAGE.md` summary table published "CLI flags 31 | 31 | 100%" as if computed.
It was not.

**Fix:** `run()` now computes `cli_flags_covered` / `uncovered_cli_flags` the
same way it does for config keys, and the summary prints a real percentage.
Mutation-tested: renaming an upstream flag to `portXX` drops coverage to 96.8%
and names the flag.

**Rule:** a coverage number that is not computed is a claim, not a measurement.
If the audit prints a percentage, it must be derived.

### The env-precedence check was a bare substring test

`"envKey in process.env" not in util` is defeated by any refactor that renames
the variable or reorders the check. It also emitted a `note`, not a `finding`,
so `--strict` never failed CI on it.

**Fix:** the check now looks for the *behaviour* — a `process.env` lookup
whose position precedes the `getConfig()` call inside `getConfigValue` — and
emits a `finding` when the pattern is gone.

### Two real module bugs, found by the skill

**1. `settings` deep-merge was shallow.** `modules/config.nix:521` used `//`,
which replaces a whole subtree. A per-account override of
`oai_settings.max_context` silently deleted `oai_settings.custom_url`. The
option description and `docs/options.md` both promised a deep merge.

Fixed with `st.deepMerge` in `lib/default.nix`, wired into both `settings` and
`files` merges. The `settingsDeepMerge` check pins it. Mutation-tested:
reverting to `//` fails the check by name.

**2. Flat dotted keys were silently inert.** `settings.common = {
"oai_settings.max_context" = 131072; }` type-checks (`types.attrsOf
types.anything`), renders flat, is written to `settings.json`, and is then
ignored by the server (direct property access, no dotted-path resolver). The
module's own example used the broken form.

Fixed with an assertion in `modules/assertions.nix` rejecting dotted attr names
under `settings.*`. The example was corrected to nested form. Verified: valid
nested settings produce 0 assertion failures; flat dotted keys produce 1.

### A stale §7 row

`COVERAGE.md` §7 listed `--requestProxyBypass` empty list as a gap. It was
already handled three times over: `cli.requestProxyBypass` exists, the empty
list is deliberately dropped in `lib/default.nix`, and
`config.requestProxy.bypass` also exists. Removed.

**Rule:** a "known improvements" list needs a "do not fix" section for items
that were already handled and would otherwise be re-found.

### The `//` trap has now bitten three times

First in `systemdOverrides.serviceConfig`, then in the `guardsFire` test rows,
and now in the `settings`/`files` merge. Each time the code *looked* correct
and the docs *promised* the right behaviour. The common factor: `//` was used
where a deep merge was needed, and nothing tested the merge depth.

**Rule:** any `//` in this codebase is a candidate bug. If the two sides can
both be attrsets, ask whether a deep merge is intended. If yes, use
`st.deepMerge`.

---

## 2026-10-19 — `configYamlRoundTrip` was not "blocked environmentally"; it was a real bug

COVERAGE.md §6 item 3 recorded the check as "blocked environmentally here"
(network / unproxied host). It was not. There was a real bug underneath.

### A host path inside a build sandbox is invisible

The check passed `caCertFile` to the `yaml` npm derivation:

```nix
caCertFile = if builtins.pathExists /etc/ssl/certs then "/etc/ssl/certs/ca-bundle.crt" else null;
```

`builtins.pathExists /etc/ssl/certs` is true on NixOS, so `caCertFile` was set to
`/etc/ssl/certs/ca-bundle.crt`. But that is a **host path**, not a store path.
The build sandbox only sees declared store-path dependencies — `/etc/ssl/certs/...`
is not one. So `NODE_EXTRA_CA_CERTS` pointed at a file the sandbox could not
read, Node fell back to its built-in CA, and npm failed with
`UNABLE_TO_GET_ISSUER_CERT_LOCALLY`.

The fix: use `pkgs.cacert`, which ships the identical bundle as a real store
path (`${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt`):

```nix
caCertFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
```

`nix flake check` now passes fully (10/10).

**Rule:** any path that must be readable *inside* a build sandbox must be a
store path. A host path — `/etc/...`, `/usr/share/...`, even one that exists on
the build host — is invisible to the sandbox unless explicitly copied in. When a
derivation needs a system resource (CA bundle, timezone data, locale archive),
take it from a package (`pkgs.cacert`, `pkgs.tzdata`, `pkgs.glibcLocales`),
never from the host filesystem.

### The lesson the same exercise teaches about "environmental" labels

"Blocked environmentally" is a claim that is never re-checked. It sat in
COVERAGE.md §6 unchallenged for multiple sessions, and each one that hit the
failure moved on. A more honest label is "not yet root-caused" — it forces the
next agent to look, and looking is all it took here.

**Rule:** when a check fails and the cause is not understood, record it as
"not yet root-caused", not "blocked environmentally". The latter is a parking
lot; the former is an open question.

### Live test result (same session)

Booted the module's real package from a throwaway store path with a Nix-declared
user, per-account settings override, and a seeded file:

- Server started, webpack compiled, listening on 127.0.0.1:8777.
- Rendered `config.yaml` is mode 444 (read-only store path) — EROFS on write is
  the design working.
- Seeded user `me` written to `_storage/`; seeded file `config/live-test.txt`
  landed with the declared content; per-account `settings.json` carries the
  `oai_settings.max_context = 131072` override.
- CSRF protection active (403 on unauthenticated API requests).
## 2026-10-19 — a justfile/devshell, and two traps it exposed

### The login route is `/api/users/login`, not `/login`

The users router is mounted at `/api/users` and the route inside it is
`/login`, so the full path is `/api/users/login`. Posting to `/login` returns
a plain-text `403 Forbidden` — which is Express's **404** handler, not an
auth failure.

This cost several debugging cycles because the symptom is indistinguishable
from a credentials problem: 403, plain text, no error in the server log. The
clue that finally broke it was that GET `/login` returned **200** while POST
`/login` returned 403 — a route that exists for GET but not POST is not an
auth failure, it is a wrong URL.

**Rule:** a 403 with no corresponding log line is not an authorisation
decision. Check the URL against the router's mount point before suspecting
credentials, and check whether the same path answers a different method.

### Backticks in a `shellHook` are command substitution

Writing prose in a dev shell's banner:

```nix
echo "refuses to read .eslintrc.cjs. `just lint` uses the version"
```

executes `just lint`. When that recipe calls `nix develop`, the dev shell runs
the shellHook, which runs the recipe, which enters the dev shell — forever.

The symptom is a `nix develop` that never returns, with a process tree that
grows one level per second:

```
nix develop . --command echo TRACE
  └─ bash /tmp/nix-shell.VDQB5y
       └─ just lint
            └─ just develop ./node_modules/.bin/eslint …
                 └─ bash nix-shell.…        ← recursion
```

`ps -ef --forest` showed it immediately; everything before that (removing the
justfile, removing `just` from the devshell, bisecting the file by halves) was
a dead end, because the trigger was the *shellHook*, not the justfile.

**Rule:** read a `shellHook` as shell, not as English. Backticks, `$( )`,
`&&` and `|` are all live inside `echo "…"`. Use single quotes in prose.

### A `path:` flake captures the working directory, untracked files and all

`nix build -f` and `builtins.getFlake "path:…"` resolve `${source}` to the
directory **as it is on disk**, including untracked files. A `git+file:` flake
resolves it to the git snapshot instead.

So a `result` symlink from `nix build --out-link result` was copied into the
package, pointing at the *previous* build's store path — which is not in the
new build's closure. The fixup phase then rejected the whole package:

```
ERROR: noBrokenSymlinks: the symlink …/result points to a missing target
```

The source filter already excluded `result` by basename. That was not enough,
because the filter only covers the flake's own `source`, and `${source}` in
`installPhase` is a path literal resolved at build time. The same hole let a
nested `.opencode/node_modules` (63 MiB) into the package, because the filter
compares the basename, not the path.

**Rule:** a source filter is not a guarantee about what `cp -r` will copy
from a path literal. Anything the install phase copies has to be cleaned up by
the install phase, not by a filter that may not have seen the file. The
`installPhase` now removes `result` and every nested `node_modules` itself.

### A linter that fails on the current tree is not a gate

`statix` and `deadnix` report ~15 real findings in the module today
(unused bindings, removable parens). Wiring them into a `lint` recipe that
exits non-zero means the recipe fails on a clean checkout, which trains
people to ignore it.

**Rule:** split linters into gates (the tree is clean, the recipe fails on a
finding) and advisory ones (the tree is not clean, the recipe reports and
exits 0). An advisory linter that fails the build is worse than no linter.

---

## 2026-10-19 — the `settings.json` surface: reachability was never the gap

The audit reports 100% for `config.yaml` and the CLI, and `COVERAGE.md` said
`settings.json` was covered "via `settings.common`". That was true, and it was
the wrong question. The user asked what could be **nixified** across the UI
tabs, and the honest answer needed a number: how many settings are there?

### "Covered" hid two different properties

*Reachable* — a Nix user can set it. True for all 410 leaf fields, through a
free-form blob.
*Discoverable* — a Nix user can know it exists, that they spelled it right,
and what it does. False for all 410, because nothing enumerated them.

A typo (`power_user.font_scal`) type-checks, is written to `settings.json`,
and is then ignored: the client reads settings by **direct property access**
(`public/scripts/power-user.js:1566`), so there is no dotted-path resolver and
no schema. The module's own examples used fictional settings
(`oai_settings.max_context`, `power_user.quick_ui`) and nobody noticed for
months — which is the strongest possible evidence that the gap was invisible.

**Rule:** for a free-form surface, coverage is not a percentage. It is an
enumeration plus a check. "The blob accepts anything" is not coverage; it is
the absence of a check.

### Deriving the surface: the sandbox that lies

The inventory is derived from upstream's source, not typed out. Getting the
*values* out of a JS object literal needs care, and the obvious approach is
wrong in a way that produces a plausible, wrong answer:

* Evaluating the literal in a `vm` context whose global proxy resolves unknown
  identifiers to a sentinel made a **spread of an imported object copy every
  global into the result** — 146 keys instead of 104, including constants
  from a *different file*. It looked like a real inventory; it was a
  concatenation of two files' globals.
* The fix is `with (SENTINEL) { … }`: `with` is the only construct that
  resolves an *arbitrary* identifier to a value, and an unresolved one
  resolves to the sentinel instead of to the sandbox global.
* `UNKNOWN` must be a proxy with `ownKeys: () => []`. Without it, spreading
  an unresolved constant yields the target's own property names.

**Rule:** when a derived artefact is a superset of what you expect, suspect
the sandbox before the source. A number that is too big is a bug until proven
otherwise — the same instinct that made the first audit run evidence of a
broken audit rather than of a clean tree.

### Nix traps, fourth and fifth time

* `lib.concatMap` is `builtins.concatMap`, which takes **one** argument (a
  list of lists). `lib.concatMap f list` silently does the wrong thing;
  `lib.concatLists (lib.map f list)` is what you meant.
* Function application binds tighter than `++`, so
  `one "x" y ++ z` parses as `one "x" (y ++ z)` — one attrset where a list of
  them was expected. The same shape as the `//` trap, and the same class:
  the code *looks* right and the type error appears three frames away.

### A store path's basename is hash-prefixed

`cp ${../scripts/extract_settings_inventory.mjs} scripts/` lands the file as
`scripts/<hash>-extract_settings_inventory.mjs`, so `node scripts/foo.mjs`
finds nothing. Same for `cp -r ${../public} public` when `public` already
exists: it nests (`public/public`). Use an explicit target name and `/.`.

**Rule:** in a check, never assume a copied file kept its name.

### A guard that refuses everything is as useless as no guard

The new `settingsKeysKnown` assertion has to be tested in **both**
directions: a rich, real configuration must produce no failure, and a typo
must produce exactly one that names the path. The first direction is the one
that catches the false positive, and false positives are what a key checker
is most likely to have — upstream's names are snake_case with a few camelCase
exceptions, and a checker that normalises them rejects the real thing.

Free-form maps (`personas`, `movingUIState`, `*.extensions`) are keyed by
*data*, not structure, so they have no enumerable leaves. They are recorded
as "open paths" and exempt.

### The client's save payload is a hard boundary

`saveSettings()` writes a fixed object of 24 top-level keys. A key outside
that set is not merely inert — the browser **deletes** it at the next save, so
it looks applied until the user touches a setting. That is a second, sharper
class of "silently wrong" than an unknown leaf, and it now has its own
assertion message.

---

## 2026-10-19 — the typed tree: 410 settings, and the price of `submodule`

The inventory made the surface knowable. The next step was to make it
*typeable*: one option per setting, generated from the same inventory, so the
option tree and the key guard can never disagree about what a real setting is.

### `types.submodule` does not do what its name suggests

The obvious way to declare a fixed set of options is `types.submodule`. Two
things about it are not in the name:

1. **`shorthandOnlyDefinesConfig` defaults to `true` for `types.submodule`.**
   A *definition* of a submodule-typed option is then treated as **config** —
   a free-form attrset merged over the declared options. An unknown key in it
   is not an error; it is an unknown key in `config`, which the module system
   has no opinion about. So the whole point — a typo must be loud — is lost,
   silently, and the tree still looks like it works.

2. **A submodule module must declare its options under `options = { … }`.**
   A module that returns a bare attrset is defining *config*, not options,
   and the error is the confusing one: "there are no options defined in `x'".

So the tree uses `types.submoduleWith { shorthandOnlyDefinesConfig = false; }`,
which treats a definition as a module — and the module system then checks
every attribute against the declared options. The error is the good one:

```
The option `services.sillytavern-nixos.settingsExtra.powerUser.font_scal' does not exist.
… Did you mean `services.sillytavern-nixos.settingsExtra.powerUser.font_scale'?
```

**Rule:** a typed tree is only as strict as its type's *definition* handling.
Check how the type treats a value, not just what it accepts.

### Two errors that `tryEval` cannot catch, and one it can

Testing "this configuration is refused" needs an error to be caught, and
`builtins.tryEval` is the only catcher. What it catches depends on *when* the
error is raised:

| Failure | Raised | Catchable? |
|---|---|---|
| unknown option | `seq checkUnmatched` on the config — lazy | **yes** |
| wrong type, at the top level of a module | during the option's `merge` — eager, but inside the config's evaluation | **yes** |
| wrong type, inside a submodule | while that submodule's OWN fixpoint is computed — eager, and outside the expression being evaluated | **no** |

So the wrong-type case is tested by asking the type directly
(`tree.typeOfPath surface path` → `.check value`), and the unknown-option
case by `tryEval` over a module system that declares exactly one option with
the tree's type. Testing the whole NixOS system for this was a minute of
evaluation per case *and* it hid the failure — `nixosSystem` computes the
module fixpoint eagerly, so the error escaped the `tryEval` entirely.

### `tryEval (f x).y` is not `tryEval ((f x).y)`

Function application binds tighter than attribute selection, so

```nix
builtins.tryEval (f x).y     # tryEval (f x), then `.y` on the RESULT
builtins.tryEval ((f x).y)   # the whole thing
```

The first form catches an error in `f x` but not one raised while evaluating
`.y` — and, worse, the error then escapes the `tryEval` entirely, so the
test *looks* like it passed with `success = true` for a configuration that
never evaluated. This cost two debugging rounds and would have produced a
check that asserted the opposite of the truth.

**Rule:** when a check is "this must fail", write the expression so the
failing part is *inside* the catcher, and verify the check by making the
failure disappear.

### A number is a number

The inventory distinguishes `int` from `float` because `Number.isInteger()`
says so about the *default*. That is a property of the default, not of the
field: `font_scale` defaults to `1` and is meant to be set to `1.2`. Mapping
the default's type straight onto the option type refuses the value a person
actually wants to write. JavaScript has one number type, so the tree uses
`types.number` for every numeric field — and the description still shows
upstream's default exactly (`1`, not `1.0`).

### `null` is not "absent"

A submodule's value contains every declared option, so an untouched tree is
182 nulls. Writing those nulls into `settings.json` would *override*
upstream's own defaults with null — the exact opposite of "not declared".
The tree therefore prunes nulls (and the empty objects they leave behind)
before anything is rendered, and the live suite asserts that no null ever
reaches the file.

---

## 2026-10-19 — "is it usable as a flake input?" found a second package

The coverage audit asks "is every config key Nix-drivable?". It does not ask
"does consuming this from OUTSIDE work?", and the answer to the second
question was no, in a way nothing in the suite could see.

### Four definitions of the same source, two of them wrong

The package's `src` was spelled out in four places: the flake's `packages`
output, the flake's overlay, the module's default `package`, and the
non-flake `default.nix`. The first two used the FILTERED tree; the last two
used the raw tree. `overlay.nix` even carried a comment saying it was "kept
byte-identical to `source` in flake.nix" — which was true of the two
*filtered* copies and false of the two unfiltered ones, and nobody noticed
because the divergence is invisible from inside the repository.

Three consequences, all visible only to a consumer:

- `pkgs.sillytavern` from the overlay and "the package the module runs" were
  **different store paths**. Applying the overlay — the documented way to
  consume this — built the same software twice, and `pkgs.sillytavern` did
  not mean "what the module runs".
- The module's package hash changed whenever a stray `node_modules` appeared
  in the source tree, so a `path:` flake input pointing at a developer's
  working copy was **not reproducible**. I confirmed this by adding 60 MiB of
  junk `node_modules` to a copy of the tree: the module's package path
  changed, while the flake's filtered package path did not.
- The unfiltered tree was copied into the store as the build input, so the
  `path:` case paid for 400 MiB it never used.

**Rule:** a value that more than one place defines belongs in exactly one
place, and the *others* import it. The fix is `lib/source.nix`, used by all
four. Note that "the comment says they are the same" is not a substitute for
"they are the same" — the comment was accurate about the pair it covered and
wrong about the pair nobody had compared.

### A check that cannot fail is worse than no check — so mutate it

The fix needed a guard, and a guard is only worth what its mutation test is
worth. `packageIdentity` asserts that the module's package, the overlay's
package and the filtered source are one derivation. Reverting the module to
`src = ../.` made it fail with the two store paths named — which is the
evidence that it is not a tautology.

The same discipline as the `libHelpers` entry above, applied to a different
kind of check: an assertion that compares two things which are *currently*
equal proves nothing until you have watched it fail on the old code.

### Two `mkDefault`s for one option is a latent conflict

`default.nix` and `modules/sillytavern.nix` both set
`services.sillytavern-nixos.package` with `mkDefault`. They agreed only by
accident: both computed the same thing from the same tree. Once the module
started computing the source with the CONSUMER's `lib` while `default.nix`
could only offer `<nixpkgs>`'s, two `lib` versions whose `cleanSourceWith`
need not agree on the output path became a "conflicting definition values"
error waiting for a consumer whose nixpkgs and channel differ.

**Rule:** one owner per option. `default.nix`'s copy was already redundant —
it had become so when the module grew its own `mkDefault` — and redundancy
that is only harmless while the two agree is a trap with a fuse.

### The overlay is optional, and saying so is part of the interface

The docs said "use the overlay so `pkgs.sillytavern` is this flake's build",
which is true but leaves the reader thinking the overlay is *required* and
that skipping it costs something. It does not: the module supplies its own
package. The overlay buys a **name** — `pkgs.sillytavern` becomes this
build, usable anywhere a package is expected. Now that all three are one
derivation, applying it is free, and `docs/installing.md` says so.

Note the name collision this creates: nixos-unstable ships its own
`pkgs.sillytavern` at the same version, whose entry point is
`src/server-global.js` and which silently ignores `--dataRoot`. The module
warns about this in three places already; the overlay section now says which
one you get depending on whether you applied it.

---

## 2026-10-19 — the named-profile layer; four Nix traps and one UI fact

Adding `presets.*` — a named profile for every dropdown the UI offers — cost
four mistakes that all have the same shape: **the code was right and the
scope was wrong**, so it failed with an error that pointed at the wrong file.

### A plain attrset is NOT recursive

```nix
{ a = 1; b = a; }        # error: undefined variable 'a'
let a = 1; in { b = a; } # fine
```

`rec` is not the default. An attribute of an attrset cannot be referred to
from a sibling unless the attrset is `rec` — and the reference has to be
**direct**, not inside a nested lambda either:

```nix
{ a = 1; b = f: a; }     # error: undefined variable 'a'
```

So a helper that needs a table its own module also defines has to live in the
`let` block, not in the exported attrset. `lib/default.nix` already had this
shape for `secretConfigPaths`; the new preset tables followed it, and two
insertions landed in the exported attrset before the pattern was noticed.

**Rule:** a value shared between two definitions goes in the `let` block and is
`inherit`ed out. It is the same rule as "one owner per option", applied to
code.

### `lib.mapAttrs'` needs `{ name, value; }`; `lib.mapAttrs` needs a set

`mapAttrs'` is `listToAttrs (mapAttrsToList f set)`, and `mapAttrsToList` is
`attrValues (mapAttrs f set)` — so `f` must return an attrset with a `name` and
a `value`. Returning a nested attrset gives "attribute 'name' missing", and
returning a LIST of them gives an error about lists where a set was expected.

The other half of the same trap: `mapAttrsToList` collects the VALUES, so a
callback that returns a list produces a list of lists. Flattening it needs
`concatLists` — and without it, every "entry" is a list and `e.name` fails
with "expected a set but found a list: [ ]", which names neither the map nor
the field.

### `lib.map` passes ONE argument

```nix
lib.map (bucket: entries: …) (lib.attrNames presets)   # `entries` is MISSING
```

`builtins.map` calls `f element`, so a two-argument lambda is partially
applied and the result is a function. The error surfaces much later, inside
whatever consumed it.

### `lib.hasInfix` takes a STRING in this nixpkgs

`lib.hasInfix "/" "a/b"` — one argument, a string. (It is `hasInfix` with a
list in some other libraries; nixpkgs' `lib.strings.hasInfix` is
`String -> String -> Bool`.) And `"/"` is a *string* in Nix, not a path, so
the `isPath` guard inside it does not fire.

### The one fact that was not obvious: where does a dropdown's LABEL come from?

SillyTavern's preset dropdowns are all "a list of named things", and the name
comes from two different places:

- **The FILE NAME** — for the four backend presets and the World Info books.
  The server sends `*_setting_names`, built from the directory listing
  (`src/endpoints/settings.js` `readPresetsFromDirectory`).
- **A `name` field INSIDE the JSON** — for the Advanced Formatting group
  (`instruct`, `context`, `sysprompt`, `reasoning`), the themes, the Moving
  UI layouts and the quick-reply sets. The client computes
  `preset_names = presets.map(x => x.name)`.

Getting this wrong is silent in one direction and harmless in the other. If
the label comes from the JSON and the module does not know that, the preset
appears in the dropdown as **"undefined"**. If the label comes from the file
and the module injects a `name` anyway, nothing breaks — the extra field is
ignored.

**Rule:** read the client, do not infer it from the file layout. The two
answers look identical on disk and are not.

### A directory name is a claim about upstream, so check it

Every bucket in `presets.*` is a claim: "the Text Completion presets live in
a directory called `TextGen Settings`". A wrong claim produces a file the
server never reads — no error, no warning, an empty dropdown.

So `scripts/extract_preset_directories.mjs` reads `USER_DIRECTORY_TEMPLATE`
out of `src/constants.js`, the API-id switch out of `src/endpoints/presets.js`
and the label sources out of the client, and the `presetsMatchUpstream` check
compares them with the module's own table. Mutating one directory name in
`lib/default.nix` fails the build with the two values named.

The check is only worth anything if it was seen to fail, so it was mutated
twice — a directory name, and one API id dropped from the label-from-content
list. Both failed with a message that said what differed.
