# Troubleshooting

Failure modes, what causes them, and what to do. Every entry here was
reproduced against a running instance at the pinned version, not inferred.

- [The build fails with "no authentication is configured"](#the-build-fails-with-no-authentication-is-configured)
- [The build fails with "two modules define systemd.services.sillytavern"](#the-build-fails-with-two-modules-define-systemd-servicessillytavern)
- [Everything returns 403 Forbidden](#everything-returns-403-forbidden)
- ["Invalid CSRF token" behind a reverse proxy](#invalid-csrf-token-behind-a-reverse-proxy)
- [EOFS: read-only file system on every start](#eofs-read-only-file-system-on-every-start)
- [The startup takes a minute](#the-startup-takes-a-minute)
- [Where is the access log?](#where-is-the-access-log)
- [Declared files are not being seeded](#declared-files-are-not-being-seeded)
- [A seeded settings.json edit keeps coming back](#a-seeded-settingsjson-edit-keeps-coming-back)
- [Extensions or plugins fail with EROFS](#extensions-or-plugins-fail-with-erofs)
- [Thumbnails are broken or missing](#thumbnails-are-broken-or-missing)
- [The account list is empty after seeding](#the-account-list-is-empty-after-seeding)
- [Checking what is actually deployed](#checking-what-is-actually-deployed)

---

## The build fails with "no authentication is configured"

The module refuses a configuration with neither `config.enableUserAccounts` nor
`config.basicAuthMode`, because SillyTavern creates a `default-user` account
with `admin: true` and an empty password in that case, and every request runs as
it. See [`installing.md`](installing.md#why-a-bare-enable--true-will-not-build).

The fix is to choose one — usually `config.enableUserAccounts = true` plus
declared `users`.

## The build fails with "two modules define systemd.services.sillytavern"

nixos-unstable ships its own `services.sillytavern`, and it is in
`module-list.nix`, so it is in scope on **every** NixOS system. Both modules own
`systemd.services.sillytavern`, `users.users.sillytavern` and
`serviceConfig.StateDirectory`, so enabling both merges two units into one.

The error names whichever directive conflicts first — usually
`serviceConfig.Restart` (`"always"` vs `"on-failure"`) — which points at the
symptom rather than the cause, and forcing past it produces a unit whose
`ExecStart` runs both packages.

**Use one or the other.** This module is `services.sillytavern-nixos`; drop
`services.sillytavern` from your configuration. If you were reaching for
`services.sillytavern` and it "worked", you were running nixpkgs' minimal
module: it symlinks one config file, passes five flags, and has no accounts, no
secrets and no JSON state.

> ⚠ Watch the namespace in **your own** configuration and scripts too.
> `osConfig.services.sillytavern` resolves to nixpkgs' module, silently — the
> attribute exists even when you meant this one.

## Everything returns 403 Forbidden

Two different causes, distinguishable by the body.

**An HTML error page** naming an IP, with `Blocked connection from …` in the
journal: the whitelist. Check `config.whitelist` against the address the request
actually arrives from. The common cause behind a proxy is
`enableForwardedWhitelist` (default `true`): the check then also tests the IP in
`X-Forwarded-For`/`X-Real-IP`, and a client can put an arbitrary one there. If
the server is reachable without your proxy in front, set
`config.enableForwardedWhitelist = false`.

A bare `Forbidden` with no HTML is `requireLoginMiddleware`
(`src/users.js:1027`): `config.enableUserAccounts` is on and you are not logged
in. `/api/ping` is `POST` and requires a session. See
[`users.md`](users.md#scripting-a-login).

**These pages are brandable.** The four HTML pages served here come from
`<dataRoot>/_errors/` and can be replaced from Nix:

```nix
errorPages = {
  forbiddenByWhitelist = ./pages/blocked.html;   # whitelist rejection
  unauthorized        = ./pages/login.html;      # failed / missing login
  hostNotAllowed      = ./pages/bad-host.html;   # Host header rejected
  urlNotFound         = ./pages/gone.html;       # any unmatched route
};
```

Until you set them, the defaults are copied from the package's `default/content`
on first start. If your branding does not appear, check the filename in
`<dataRoot>/_errors/` — upstream's is `forbidden-by-whitelist.html`, with
hyphens, and a file named `forbiddenByWhitelist.html` is never read.

## "Invalid CSRF token" behind a reverse proxy

```
ForbiddenError: Invalid CSRF token. Please refresh the page and try again.
```

SillyTavern protects every state-changing request with a token bound to the
session cookie (`csrfSync`, `src/server-main.js:166`). Two usual causes:

1. **The proxy is not forwarding cookies**, or is rewriting the `Origin` header.
   The session cookie must survive the round trip.
2. **Websockets or a subdomain split** — a token issued for one origin and sent
   to another will not match.

**Do not set `config.disableCsrfProtection = true` to make this go away.** It is
upstream's NOT RECOMMENDED and this project's, for the same reason: it exists to
paper over a proxy that rewrites `Origin`, and it removes the only thing
standing between a cross-site request and your instance. Fix the proxy instead.

## EROFS: read-only file system on every start

```
Could not add missing config values to config.yaml Error: EROFS:
read-only file system, open '/nix/store/…-sillytavern-config.yaml'
```

**This is expected.** The config file is a read-only store path by design, and
the server tries to rewrite it whenever `addMissingConfigValues` thinks a key is
missing — which includes the three credential paths this module strips on
purpose (`ssl.keyPassphrase`, `basicAuthUser.password`, `requestProxy.url`), so
it will happen on every start. The body of that function is wrapped in a
try/catch that only logs.

It is safe because every read goes through `getConfigValue(key, default)`, which
falls back to an in-code default when neither the environment nor the file
supplies one. Upstream's own comment agrees: "Configs are read-only. Use
environment variables instead."

You will see three keys listed as missing. If you see **others**, that is a real
signal — an unmodelled upstream key. `configYamlRoundTrip` catches that at build
time; `extraConfig` is the escape hatch for it.

## The startup takes a minute

The server awaits `runWebpackCompiler({ pruneCache: true })` **before** it starts
listening (`src/server-main.js`), and recompiles the frontend bundle on every
start. This is why `startupTimeout` defaults to 180 seconds.

For a real liveness signal rather than "the process exists", set
`config.heartbeatInterval`:

```nix
services.sillytavern-nixos.config.heartbeatInterval = 30;
```

The module then wires SillyTavern's own `src/healthcheck.js` into a systemd
timer. Both `SILLYTAVERN_HEARTBEATINTERVAL` and `SILLYTAVERN_DATAROOT` are
exported — without the former the probe parses `0`, treats that as "disabled"
and exits `0` immediately, reporting success without checking anything.

## Where is the access log?

At `<dataRoot>/access.log` — `/var/lib/sillytavern/access.log` — **not** in the
server directory. `src/middleware/accessLogWriter.js:10`:

```js
export const getAccessLogPath = () => path.join(globalThis.DATA_ROOT, 'access.log');
```

which is inside the `StateDirectory` systemd keeps writable. Nothing needs
redirecting it.

New client IPs are *also* logged to the journal at info level, so a busy instance
produces two records; `config.logging.minLogLevel` controls the console one.

## Declared files are not being seeded

Check the `preStart` output in the journal — both seeders report what they did:

```
sillytavern: seeding JSON state into /var/lib/sillytavern (policy: missing)
st-seed-files: created themes/Azure.json
st-seed-files: 6 written, 1 left alone (policy=missing)
```

`left alone` means the file already existed and `seedPolicy = "missing"` was in
effect. That is the default and it is usually what you want; see the next
section.

The usual cause of a file never appearing at all is that its handle is not a
declared account — the module asserts that, because SillyTavern builds its
account list from `_storage/`, not from directory names, so a stray directory is
silently ignored.

## A seeded settings.json edit keeps coming back

`settings.json` is **deep-merged, never replaced**, under both policies. The
server rewrites that file on nearly every interaction and carries keys nobody
enumerated, so a wholesale write would delete them — that is data loss, not
strictness.

The consequence is that `settings.json` is not authoritative even under
`seedPolicy = "overwrite"`: the server writes it at runtime, so anything the UI
changes diverges again until the next activation. Presets and themes are plain
files and behave the way you would expect.

If you want a setting the UI cannot drift away from, put it somewhere the UI does
not own — `customCss` is the only such surface this module writes at the data
root.

## Extensions or plugins fail with EROFS

Declared extensions and plugins are `fetchgit` store paths under the package, and
they are read-only. Any attempt to `git pull` into one fails.

The module turns auto-update off for you when the corresponding list is
non-empty, and asserts if you set it back to `true`. To update one, change its
`rev` and rebuild:

```nix
services.sillytavern-nixos.extensions.vector-storage.rev = "refs/tags/v3.1.0";
```

A `rev` must be a tag or a full 40-character commit SHA; a branch name is
rejected, because a store path cannot be rebuilt reproducibly from one.

## Thumbnails are broken or missing

`config.thumbnails.dimensions.<kind>` is a **two-element list**:

```nix
config.thumbnails.dimensions = {
  bg = [ 160 90 ];
  avatar = [ 96 144 ];
};
```

The server destructures it (`const [configWidth, configHeight] =
dimensions[type]`, `src/endpoints/thumbnails.js:215`) and computes
`width * height` for its budget check
(`src/endpoints/image-metadata.js:52`). A record — `{ width = 160; height = 90; }`
— renders a config the server considers incomplete, and you get, in the journal:

```
Adding missing config values to config.yaml: [
  'thumbnails.dimensions.bg.0', 'thumbnails.dimensions.bg.1', … ]
Failed to process image … TypeError: object is not iterable
```

Every image fails, because `Array.isArray()` is false and the destructuring
throws. This module models it as a list, and `configYamlRoundTrip` fails the build
if it ever drifts.

Only affects **new** thumbnails; clear the user's `thumbnails/` directory to
regenerate existing ones.

## The account list is empty after seeding

Three things to check:

1. **`config.enableUserAccounts` is on.** Without it the server ignores the
   accounts entirely and creates its own `default-user`.
2. **The seeder actually ran.** `preStart` output, as above. A Python traceback
   there means the seeder refused — most often a missing secret file, in which
   case agenix has not decrypted it yet.
3. **Ownership.** `_storage/` is `0700` and owned by the service account. If the
   data root was copied in as root, the server cannot read the account database.

## Checking what is actually deployed

```bash
# The rendered config: a store path, 0444
systemctl cat sillytavern | grep -- --configPath
nix-store --cat /nix/store/…-sillytavern-config.yaml

# The argv, one element per line
systemctl show sillytavern -p ExecStart

# What was seeded, and what was left alone
journalctl -u sillytavern -b | grep 'sillytavern:\|st-seed'

# What the server thinks is missing from its config
journalctl -u sillytavern -b | grep -A20 'Adding missing config values'
```

The last one should list exactly three keys — the stripped credentials. Anything
else is an unmodelled upstream option.
