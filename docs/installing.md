# Installing

How to get a running instance, and the two decisions (authentication and TLS)
that will otherwise block you.

- [Adding the flake](#adding-the-flake)
- [A minimal configuration](#a-minimal-configuration)
- [Why a bare `enable = true` will not build](#why-a-bare-enable--true-will-not-build)
- [Where the data lives](#where-the-data-lives)
- [TLS: prefer a reverse proxy](#tls-prefer-a-reverse-proxy)
- [Terminating TLS in SillyTavern instead](#terminating-tls-in-sillytavern-instead)
- [Opening the port](#opening-the-port)
- [Reverse proxy notes](#reverse-proxy-notes)
- [Migrating an existing install](#migrating-an-existing-install)

---

## Adding the flake

```nix
{
  inputs.sillytavern.url = "github:Cairnstew/SillyTavern";

  outputs = { nixpkgs, sillytavern, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        sillytavern.nixosModules.sillytavern
        ./configuration.nix
      ];
    };
  };
}
```

Then either use the overlay so `pkgs.sillytavern` is this flake's build:

```nix
nixpkgs.overlays = [ sillytavern.overlays.default ];
```

…or set the package yourself, which works without the overlay:

```nix
services.sillytavern-nixos.package =
  sillytavern.packages.${pkgs.system}.sillytavern;
```

The module sets `package` itself when you do not, so this second form is only
needed if something else in your configuration must influence the build.

> The overlay is **not** required, and applying it does not build a second
> copy of anything. The module, the overlay and the flake's `packages` output
> all resolve to the same derivation — the `packageIdentity` check in
> `nix flake check` fails the build if they ever drift apart again.
>
> What the overlay buys you is the NAME: `pkgs.sillytavern` becomes this
> flake's build, so it can be used anywhere a package is expected (a reverse
> proxy's `environment.systemPackages`, a `homeManager` module, another
> flake's `nixpkgs.overlays`).
>
> Beware the name collision: nixos-unstable ships a `pkgs.sillytavern` of the
> same version, and it is **not** this build. If you apply this overlay, yours
> wins; if you do not, `pkgs.sillytavern` is nixpkgs' and is incompatible with
> this module (see the warning below).

> ⚠ **Do not point `package` at `pkgs.sillytavern` from a bare nixpkgs.** The
> module's `package` option says "no package was supplied" if you import the
> option and config files directly, and its error message explains why the
> nixpkgs package of the same name and version is not a substitute: its `bin`
> entry point is `src/server-global.js`, which sets `FORCE_GLOBAL_MODE`. In that
> mode SillyTavern ignores `--configPath` and `--dataRoot` and writes to the
> service account's `~/.local/share` instead of the systemd `StateDirectory`.
> The server starts, serves HTTP, and silently ignores everything this module
> configured.

## A minimal configuration

```nix
{
  services.sillytavern-nixos = {
    enable = true;
    package = inputs.sillytavern.packages.${pkgs.system}.sillytavern;

    # Loopback only. Reach it with an SSH tunnel or a reverse proxy on the same
    # host — this is the intended topology and the default.
    config.port = 8000;

    config.enableUserAccounts = true;
    users.seanc = {
      name = "Sean";
      admin = true;
      passwordFile = config.age.secrets.sillytavern-seanc.path;
    };

    # Declarative per-account defaults: sampled at 0.7, 128k context.
    settings.common.oai_settings = {
      temp_openai = 0.7;
      openai_max_context = 131072;
    };
  };
}
```

`docs/options.md` covers the option surface; `docs/users.md` covers accounts.

## Why a bare `enable = true` will not build

This is deliberate. With `config.enableUserAccounts` and `config.basicAuthMode`
both false, SillyTavern creates a `default-user` account automatically **with
`admin: true` and an empty password**, and every request runs as it. An empty
password cannot be *logged into* — but the account is still an administrator,
and if `config.listen` is true the whole LLM proxy is reachable
unauthenticated, along with whatever API keys users have configured.

So the module refuses to build until you have chosen:

| You want | Set |
|---|---|
| Loopback only, behind a proxy or tunnel | `config.listen = false` (the default) |
| Real accounts | `config.enableUserAccounts = true` **and** declare `users` |
| HTTP basic auth (a blunt instrument) | `config.basicAuthMode = true` |

Turning on `config.listen` with no authentication is a second, louder assertion
unless you have also enabled `hostWhitelist` or `privateAddressWhitelist`.

## Where the data lives

Everything mutable is under one systemd `StateDirectory`:

```
/var/lib/sillytavern/            # the data root, 0700, owned by `sillytavern`
├── cookie-secret.txt            # generated on first start; do not copy between instances
├── access.log                   # logging.enableAccessLog — IN the data root
├── content.log                  # content-manager bookkeeping
├── _css/user.css                # instance stylesheet — see customCss
├── _storage/                    # node-persist account database
├── _webpack/                    # frontend bundle cache, rebuilt on every start
├── _cache/                      # transformers.js ONNX model cache
├── _errors/                     # auth/whitelist/404 pages — see errorPages
└── <handle>/                    # one directory per account
    ├── settings.json            # per-account UI state
    ├── secrets.json             # provider API keys
    ├── characters/  worlds/  chats/  themes/
    ├── instruct/  context/  sysprompt/  reasoning/
    └── TextGen Settings/  KoboldAI Settings/  NovelAI Settings/
```

Two consequences worth knowing:

- **The state directory is the only writable path the unit has.**
  `ProtectSystem=strict` is on, and systemd exempts `StateDirectory` from it.
  Anything you point the server at outside `/var/lib/sillytavern` — a
  `config.dataRoot` override, a writable `ssl.certPath` — is read-only to it.
- **Startup is not instant.** The server recompiles its frontend bundle with
  webpack before it starts listening (`runWebpackCompiler` in
  `src/server-main.js`), so the first start after an upgrade is tens of seconds.
  `startupTimeout` (default 180s) is sized for that. If you want a real liveness
  signal, set `config.heartbeatInterval` and the module wires SillyTavern's own
  `src/healthcheck.js` into a systemd timer.

`config.yaml` itself is **not** here. It is a read-only store path rendered from
your configuration. The server tries to rewrite it on startup when it finds keys
it does not recognise, fails with `EROFS`, and carries on — every read falls back
to an in-code default, so this is expected and harmless. You will see it in the
journal on every start.

## TLS: prefer a reverse proxy

SillyTavern's own TLS works, but enabling it makes certificates, renewal and
cipher policy your problem, and it puts TLS on a service that has no other reason
to have it. Terminate at a reverse proxy on the same host instead, and keep
`config.listen = false` so only the proxy can reach the server.

```nix
services.sillytavern-nixos = {
  enable = true;
  openFirewall = false;          # loopback bind needs no hole
};
```

This module does not depend on any particular proxy, and deliberately does not
open one for you. It exposes the data you need to wire into whatever you use:

```nix
proxy.upstreams = lib.mkMerge (
  map inputs.sillytavern.lib.mkProxyUpstream
    config.services.sillytavern-nixos.proxyUpstreams
);
```

…or, for the default instance, without declaring the list at all:

```nix
proxy.upstreams = [ inputs.sillytavern.lib.mkProxyUpstream { inherit config; } ];
```

### Four settings a proxy in front of SillyTavern gets wrong

These are not opinions. Each produces a failure that looks like something else,
and each is why `proxyUpstreams` carries the value instead of leaving it to be
rediscovered in production.

**1. Request body size.** `src/server-main.js` configures its body parsers with a
`500mb` limit, because character cards, backgrounds, chat imports and
`settings.json` are all uploaded as JSON. **nginx's `client_max_body_size`
defaults to 1 MB.** Without raising it the first avatar upload fails with a bare
`413`, and nothing in the SillyTavern journal explains it.

```nix
proxyUpstreams = [ { inherit (config) maxBodySize; # = "512m" } ];
```

**2. The `Host` header.** `config.hostWhitelist.enabled` makes
`src/middleware/hostWhitelist.js` match `req.headers.host`. Behind a proxy that
header carries the **public** name, not `localhost`, so enabling the whitelist
without listing it rejects every request. The module asserts this combination.

```nix
config.hostWhitelist.enabled = true;
config.hostWhitelist.hosts = [ "st.example.com" ];   # a leading dot = subdomain
```

**3. `X-Forwarded-For` must be REPLACED, not appended.**
`config.enableForwardedWhitelist` defaults to **true**, and
`src/express-common.js` prefers `x-real-ip`, then `cf-connecting-ip`, then the
*first* `X-Forwarded-For` entry. An appending proxy lets a client send its own
header with an address of their choosing still first — so `whitelist` and
`rateLimiting.preferRealIpHeader` then trust a spoofed IP.

In nginx that means `$remote_addr`, **not** `$proxy_add_x_forwarded_for`. Caddy
replaces by default. Declaring it records the intent, and the module refuses
`forwardedFor = "append"` while `enableForwardedWhitelist` is on:

```nix
proxyUpstreams = [ { inherit (config) forwardedFor; # = "replace" } ];
```

**4. Read timeout.** Most proxies default to 60 seconds of *inactivity* (nginx
`proxy_read_timeout`). A long LLM generation streaming tokens over SSE can stall
longer than that between chunks, and the symptom is a mid-answer `502` that reads
like the model giving up. Set it above the longest expected gap between tokens —
it resets on every write, so it does not have to cover the whole response.

```nix
proxyUpstreams = [ { inherit (config) readTimeout; # = "1h" } ];
```

See the `proxyUpstreams` option for the full shape.

## Terminating TLS in SillyTavern instead

If you really are terminating TLS in the server, the certificate and key have to
reach it somehow. A **relative** `certPath`/`keyPath` cannot work: `server.js` does
`process.chdir(serverDirectory)` at startup, and that directory is the read-only
Nix store. There are two ways out, and the module has an assertion for each.

Use the convenience options, which copy the files into the package at build time
and point the config at absolute store paths:

```nix
services.sillytavern-nixos = {
  enable = true;
  config.ssl.enabled = true;
  config.enableUserAccounts = true;
  config.listen = true;

  ssl.certFile = "${config.networking.x509.certificates.st}.crt";
  ssl.keyFile  = "${config.networking.x509.certificates.st}.key";

  openFirewall = true;
};
```

Or manage the paths yourself:

```nix
config.ssl.certPath = "/etc/sillytavern/cert.pem";   # absolute, outside the store
config.ssl.keyPath  = "/etc/sillytavern/privkey.pem";
```

…which means adding that directory to the unit's `ReadWritePaths` via
`systemdOverrides`, since `ProtectSystem=strict` applies:

```nix
services.sillytavern-nixos.systemdOverrides = {
  serviceConfig.ReadWritePaths = [ "/etc/sillytavern" ];
};
```

> **The `serviceConfig.` prefix matters.** Unit-level entries in
> `systemdOverrides` (`description`, `after`, `wantedBy`, …) and `serviceConfig`
> entries (`Restart`, `LimitNOFILE`, `ReadWritePaths`, …) are different option
> sets. Putting `Restart` at the top level fails with *"The option
> `systemd.services.sillytavern.Restart` does not exist"*; putting
> `ReadWritePaths` anywhere other than under `serviceConfig` fails the same way
> the other direction.

A `serviceConfig` block here is **merged** into the one this module builds, so
the rest of the unit — `ExecStart`, `User`, `StateDirectory`, the hardening
block — is preserved and only the keys you name change. (It used to be applied
to the whole unit, where attrset `//` *replaces*: a single `serviceConfig` key
silently discarded the entire block and left a unit that never started, with
`nixos-rebuild` still reporting success.)

If `ssl.enabled = true` and the server cannot open the certificate,
`checkSslOptions` in `src/server-startup.js` exits during startup — which is why
the module refuses the combination rather than letting the unit fail-loop.

**Passphrases never go in `config.ssl.keyPassphrase`.** That value is rendered
into a store file, which is world-readable and kept forever by the garbage
collector. Use the file-backed option, which arrives as `SILLYTAVERN_SSL_KEYPASSPHRASE`
— the mechanism upstream's own comment recommends:

```nix
ssl.keyPassphraseFile = config.age.secrets.sillytavern-tls-passphrase.path;
```

## Opening the port

`openFirewall = true` opens `config.port` in the nftables ruleset. It defaults to
**false**, because the intended topology is loopback plus a proxy or an SSH
tunnel, and turning it on exposes an HTTP service with no TLS of its own to every
network the host is on.

```bash
ssh -L 8000:127.0.0.1:8000 myhost   # then open http://localhost:8000
```

## Reverse proxy notes

- **Do not set `config.disableCsrfProtection = true` to fix a proxy problem.** It
   is upstream's NOT RECOMMENDED for the same reason it is flagged here. See
   `docs/troubleshooting.md` for what to do instead.
- **`enableForwardedWhitelist` defaults to `true`.** That is correct behind a
   proxy you control, and a hole without one: a client can send an arbitrary
   `X-Forwarded-For` and match any entry in `whitelist`. It only matters when
   `whitelistMode` is on, which it is by default — so if you expose the server
   without a proxy, set `config.enableForwardedWhitelist = false`.
- **`config.hostWhitelist`** is cheap protection against Host-header attacks and
   DNS rebinding, and worth enabling on any non-loopback bind.

## Migrating an existing install

The data root is the whole state. Copy it, keep ownership, and you are done:

```bash
systemctl stop sillytavern
sudo -u sillytavern tar -C /var/lib -cf - sillytavern | sudo -u sillytavern \
  tar -C /new/location -xf -
sudo chown -R sillytavern:sillytavern /new/location/sillytavern
systemctl start sillytavern
```

From a Docker deployment, the equivalent is `docker cp` the container's `/data`
directory (or the volume behind it) into `/var/lib/sillytavern`, preserving
ownership. Accounts live in `_storage/`, so they come with it.

Two things to expect:

- **`cookie-secret.txt` changes** if you do not copy it, and every session is
  invalidated. Harmless; everyone logs in again.
- **Version skew matters.** A newer SillyTavern migrates account records and
  chat files on startup. Going *back* to an older version after it has migrated
  is not supported — take a copy before the first boot on the new build.

To move the data root rather than copy it, set `stateDirectory`:

```nix
services.sillytavern-nixos.stateDirectory = "sillytavern-alt";
```

`dataRoot` derives from it, and `cli.dataRoot` is asserted to match, so the one
option moves both. Note this does **not** rename the systemd service or the
service account, so ownership of the new directory has to be right:

```bash
sudo chown -R sillytavern:sillytavern /var/lib/sillytavern-alt
```
