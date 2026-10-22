# Getting started

Using this repository as a flake input to run SillyTavern on NixOS.

This is the guide for a **consumer**: someone who wants the module working, not
someone who wants to change the module. It covers what the flake exposes, how
to point a configuration at it, what the module does on your behalf, and the
two ways to get it wrong that cost the most time.

- [What you get](#what-you-get)
- [Adding the flake input](#adding-the-flake-input)
- [Pinning](#pinning)
- [The outputs](#the-outputs)
- [A configuration that works](#a-configuration-that-works)
- [What the module does for you](#what-the-module-does-for-you)
- [A fuller configuration](#a-fuller-configuration)
- [The Home Manager half](#the-home-manager-half)
- [Without a flake](#without-a-flake)
- [Checking a configuration](#checking-a-configuration)
- [Upgrading](#upgrading)
- [Where to go next](#where-to-go-next)

---

## What you get

A NixOS module, `services.sillytavern-nixos`, that owns the whole lifecycle of
the server:

| | |
|---|---|
| **The build** | one store path, built from this repository's source, with the dependency tree pinned by the committed lockfile |
| **The config** | `config.yaml` rendered into the store — every upstream key, one Nix option each |
| **The data** | a systemd `StateDirectory` at `/var/lib/sillytavern`, with accounts, per-account JSON state and API keys seeded at activation |
| **The unit** | a hardened systemd service that starts at boot, with `ProtectSystem=strict`, a tmpfiles rule for the access log, and an optional healthcheck timer |
| **The surface** | every `config.yaml` key, every CLI flag, every `SILLYTAVERN_*` variable, the UI's own `settings.json`, the named profiles, and the provider API keys |

Two things it deliberately does **not** do: it does not open a port (the
intended topology is loopback plus a reverse proxy or an SSH tunnel), and it
does not manage TLS certificates (terminate at a proxy — see
[`installing.md`](installing.md)).

## Adding the flake input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sillytavern.url = "github:Cairnstew/SillyTavern";
  };
}
```

That is the whole requirement. The module brings its own package, so there is
nothing else to wire up.

> **`inputs.sillytavern.inputs.nixpkgs.follows = "nixpkgs"` is worth adding.**
> This flake carries a `nixpkgs` input of its own, used for `self.lib` (the
> exported renderers) and for the test suite. Without `follows`, your lock file
> contains two nixpkgs. The module itself always uses **your** nixpkgs — the
> `pkgs` your `nixosSystem` provides — so `follows` affects only the exported
> helpers, never the package that runs.

## Pinning

The default is the fork's `release` branch, which tracks the current
application version. A consumer who wants a fixed build pins a commit:

```nix
inputs.sillytavern.url = "github:Cairnstew/SillyTavern?ref=<commit-sha>";
```

Then `nix flake lock` to record it, and `nix flake update sillytavern` to
move it later.

> ⚠ **Do not pin a version tag.** The tags in this repository (`1.10.0`,
> `1.19.0`, …) are **upstream SillyTavern's application releases**, inherited
> from the upstream project. They predate the Nix packaging entirely: tag
> `1.19.0` contains no `flake.nix`, no `modules/` and no `lib/`, so
> `?ref=1.19.0` gives you a flake with no module in it and an error that says
> nothing about the cause. The tags track the *application*; this repository's
> *packaging* lives only on `release`.

## The outputs

| Output | What it is |
|---|---|
| `nixosModules.sillytavern` | the system module — `services.sillytavern-nixos` |
| `homeModules.sillytavern` | the Home Manager half — `sillytavern` |
| `packages.<system>.sillytavern` | the server, built from this repository |
| `packages.<system>.default` | the same derivation; what `nix flake check` builds |
| `overlays.default` | adds `pkgs.sillytavern` |
| `lib` | the shared renderers: `mkProxyUpstream`, `keyToEnv`, `renderYaml`, `userKeyFor`, … |
| `devShells.default` | nodejs, npm, python3 and the app's toolchain |
| `checks.<system>.*` | the module's own evaluation-time suite |
| `apps.<system>.{default,seeder}` | run the server; seed accounts into a data root |

`nixosModules.default` and `homeModules.default` are aliases of the same two
modules, for consumers who prefer the shorter name.

> **The overlay is optional, and `pkgs.sillytavern` is a trap without it.**
> nixos-unstable ships its own `pkgs.sillytavern` — the same application, built
> differently. It is **not** compatible with this module: its entry point sets
> `FORCE_GLOBAL_MODE`, in which SillyTavern ignores `--configPath` and
> `--dataRoot` and writes to the service account's home directory instead of
> the state directory. The server starts, serves HTTP, and silently ignores
> everything the module configured. Apply the overlay and yours wins; do not
> apply it and `pkgs.sillytavern` is nixpkgs'. See
> [`installing.md`](installing.md#adding-the-flake).

## A configuration that works

```nix
{
  inputs.sillytavern.url = "github:Cairnstew/SillyTavern";

  outputs = { nixpkgs, sillytavern, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        sillytavern.nixosModules.sillytavern
        {
          nixpkgs.overlays = [ sillytavern.overlays.default ];

          services.sillytavern-nixos = {
            enable = true;

            config = {
              port = 8000;
              # Loopback only. Reach it with an SSH tunnel or a reverse proxy
              # on the same host — this is the intended topology.
              listen = false;
              enableUserAccounts = true;
            };

            users.seanc = {
              name = "Sean";
              admin = true;
              # A path to a file containing the password. `config.age.secrets.…`
              # is the usual source; any file you control works.
              passwordFile = config.age.secrets.sillytavern-seanc.path;
            };
          };
        }
      ];
    };
  };
}
```

Two things in there are **required**, and the module refuses to build without
them, because getting them wrong is silent:

- **`config.enableUserAccounts = true` and a declared `users` entry.** With
  accounts disabled, SillyTavern creates a `default-user` account on first
  start with `admin: true` and an **empty** password — and an empty password
  means *passwordless*, not *disabled*. The login check is
  `if (user.password && user.password !== …)`, so the comparison is skipped
  and any password at all works. The server would come up as an open
  administrator.
- **`config.listen = false`**, unless you have chosen an authentication method
  and said so explicitly.

The alternative to accounts is `config.basicAuthMode = true` (HTTP basic auth
— a blunt instrument) or an SSO provider. The three choices are tabulated in
[`installing.md`](installing.md#why-a-bare-enable--true-will-not-build).

`passwordFile` is a **path to a file containing the password**, never the
password itself: an inline string would be copied into the Nix store, which is
world-readable and kept until the garbage collector runs. `config.age.secrets.…`
is the usual source, but any file you control works.

## What the module does for you

At `nixos-rebuild` time, in this order:

1. **Builds the server** into a store path, with `node_modules` from the
   committed lockfile and nothing else in the tree.
2. **Renders `config.yaml`** from your `config` and `cli` options into a
   read-only store path, and renders the CLI arguments into argv.
3. **Creates the data root** — `/var/lib/sillytavern`, owned by the
   `sillytavern` service account, and nothing else writable.
4. **Seeds accounts and state at activation**: the accounts you declared, the
   per-account `settings.json`, the presets, the themes, the world books, and
   the API keys.
5. **Installs the unit**, hardened, ordered after `network-online.target` and
   pulled in by `multi-user.target` so it actually starts at boot.

Two consequences worth knowing before you deploy:

- **Startup is not instant.** The server recompiles its frontend bundle with
  webpack before it listens, so the first start after an upgrade takes tens of
  seconds. `startupTimeout` (180s) is sized for that.
- **Seeding is create-only.** An account that already exists is left alone,
  so a password changed through the UI survives the next rebuild. The same is
  true of API keys under the default `seedPolicy = "missing"`: a key you
  added in the UI is never overwritten.

## A fuller configuration

```nix
services.sillytavern-nixos = {
  enable = true;

  config = {
    port = 8000;
    listen = false;
    enableUserAccounts = true;
    hostWhitelist = {
      enabled = true;
      hosts = [ "st.example.com" ];   # a leading dot = subdomains
    };
  };

  users.seanc = {
    name = "Sean";
    admin = true;
    passwordFile = config.age.secrets.sillytavern-seanc.path;
  };

  # Provider API keys. `value` is a PATH to a file, never the key itself.
  secrets.byUser.seanc = {
    api_key_openai.value = config.age.secrets.openai-api-key.path;
    api_key_claude.value = config.age.secrets.anthropic-api-key.path;
  };

  # Declarative UI state. `settings.common` applies to every account;
  # `settings.byUser.<handle>` overrides it for one.
  settings.common.oai_settings = {
    temp_openai = 0.7;
    openai_max_context = 131072;
  };
  settings.byUser.seanc.oai_settings.stream_openai = true;

  # The same surface, but TYPED: every setting upstream has is an option with
  # upstream's own name, and a typo is an evaluation error rather than a key
  # that is written to disk and never read.
  settingsExtra.powerUser.auto_advance = true;

  # Named profiles, by bucket and name. The path is derived, so the file
  # lands where the server looks for it.
  presets.byUser.seanc.openai.myPreset = {
    json = {
      openai_model = "gpt-5.2";
      openai_max_context = 131072;
    };
  };

  # The instance-wide stylesheet. A PATH to a CSS file, not a string.
  customCss = ./ui-overrides.css;

  # A local inference server. SillyTavern does not run the model — it talks
  # to the server that does. `server_urls` is keyed by backend.
  settingsExtra.textGenerationSettings = {
    type = "ollama";
    server_urls.ollama = "http://127.0.0.1:11434";
    ollama_model = "llama3.1:8b";
  };

  # A local SPEECH server is a third module, like the LLM one. It serves an
  # OpenAI-compatible /v1/audio/speech and comes with VRAM/RAM guards.
  #   imports = [ inputs.sillytavern.nixosModules.breeze-tts ];
  #   services.breeze-tts-nixos = { enable = true; model = "q4_k"; };
  # See docs/tts.md.

  # The models SillyTavern runs ITSELF — the ONNX weights behind the
  # extensions — in the Nix store, so they are never downloaded at runtime.
  models.byId."Xenova/whisper-small" = pkgs.fetchFromGitHub {
    owner = "Xenova";
    repo = "whisper-small";
    rev = "…";
    hash = "sha256-…";
  };
  config.extensions.models.speechToText = "Xenova/whisper-small";

  # The four settings a reverse proxy in front of SillyTavern gets wrong.
  proxyUpstreams = [ { maxBodySize = "512m"; readTimeout = "1h"; } ];
};
```

Notes on the parts that are not obvious:

- **`settings` vs `settingsExtra`.** `settings.*` is the free-form map — any
  path in `settings.json` is accepted, and a typo is silently inert.
  `settingsExtra.*` is the typed mirror of the same surface, generated from
  upstream's own sources, so a typo is **refused at evaluation** with the
  correct spelling suggested. Prefer it. The full map is in
  [`settings-surface.md`](settings-surface.md).
- **`secrets.byUser.<handle>`** takes SillyTavern's own key names
  (`api_key_openai`, `api_key_claude`, …) and writes records the UI's key
  manager reads, so the key is usable in the browser exactly as if you had
  typed it there.
- **`presets.byUser.<handle>.<bucket>.<name>`** covers the four backend
  presets, the Advanced Formatting group, themes, Moving UI layouts, quick
  replies, world books and workflows. The buckets are the server's own
  directory names; the module derives the path and asserts the directory
  against upstream, so a wrong name fails the build.
- **`models.*` is for the models SillyTavern runs itself** — the ONNX
  weights behind the extensions (embeddings, captioning, speech-to-text,
  text-to-speech). `models.byId` puts them in the Nix store, inside the
  package; `models.directory` points the server at a directory you manage
  yourself. A local LLM is NOT one of these: SillyTavern has no inference
  engine, so a GGUF file belongs to the llama.cpp or Ollama server, and
  SillyTavern is pointed at that. See
  [`options.md`](options.md#locally-run-models-models).
- **`customCss` is a path**, not a string: `./ui-overrides.css`, copied to
  `<dataRoot>/_css/user.css`. It is the one file this module **overwrites on
  every activation** — the stylesheet is Nix-authoritative, so edit the file
  you point at, not the one in the data root.
- **`proxyUpstreams`** is not a proxy — it is the data a proxy needs.
  `mkProxyUpstream` emits the request-body ceiling, the `Host` header, the
  `X-Forwarded-For` mode and the read timeout, each of which produces a
  failure that looks like something else. `port` defaults to the instance's
  own `config.port` and `forwardedFor` already defaults to `"replace"`, so
  the list only needs the values that differ. The four are explained in
  [`installing.md`](installing.md#four-settings-a-proxy-in-front-of-sillytavern-gets-wrong).

> ⚠ **Never write `inherit (config)` inside `proxyUpstreams`.** The value
> would contain the whole NixOS configuration, which contains
> `proxyUpstreams` — so evaluating the list evaluates itself and the
> evaluation never terminates. It does not fail with an error; it hangs, with
> no output, until you interrupt it. Write the values out instead:
> `proxyUpstreams = [ { maxBodySize = "512m"; } ];`

## The Home Manager half

The system module owns the server. The **Home Manager** module owns the other
end of the connection: reaching the UI, and knowing which account to log in
as. It is a separate module, in a separate namespace, because home-manager
configuration and NixOS configuration are separate worlds.

Its options live under `sillytavern`, **not** `services.sillytavern`:

```nix
home-manager.users.seanc = nixpkgs.lib.mkMerge [
  {
    home.stateVersion = "24.05";

    sillytavern = {
      enable = true;
      accounts = [ "seanc" ];
      loginScript = true;

      loginCommand = ''
        jar=$(mktemp)
        token=$(curl --fail-with-body --silent --show-error \
          --cookie-jar "$jar" --cookie "$jar" \
          "$SILLYTAVERN_URL/csrf-token" | jq -r .token)
        curl --fail-with-body --silent --show-error \
          --cookie-jar "$jar" --cookie "$jar" \
          --header "X-CSRF-Token: $token" \
          --header 'Content-Type: application/json' \
          --data "{\"handle\":\"$ACCOUNT\",\"password\":\"$(cat "$PASSWORD_FILE")\"}" \
          "$SILLYTAVERN_URL/api/users/login"
        rm -f "$jar"
      '';
    };
  }

  sillytavern.homeModules.sillytavern
];
```

Four things about that snippet that are not obvious from the syntax:

- **The module has to be added to the user's home-manager configuration**, as
  in the `mkMerge` above. It is not picked up by importing the system module.
- **The handle must be a NixOS user too.** Home Manager resolves
  `homeDirectory` and `username` from `config.users.users.<name>`, so
  `users.users.seanc` has to exist in the *system* configuration or the
  evaluation fails with `attribute 'seanc' missing`.
- **`loginCommand` runs in a shell, not in Nix.** The generated script exports
  `ACCOUNT`, `SILLYTAVERN_URL` and `SILLYTAVERN_HOST` before running it.
  Those are *shell* variables: writing `"${ACCOUNT}"` fails at evaluation with
  `undefined variable 'ACCOUNT'`, and so does interpolating the sibling option
  `url`, because a Nix attribute set is not recursive. `loginPackages` puts
  the binaries your command shells out to on the script's `PATH` — it defaults
  to `curl` and `jq`, and a `writeShellApplication` script has a minimal
  `PATH` without them.
- **It is inert without a server.** The module reads the instance out of the
  *system* configuration, so importing it into a home-manager configuration
  with no SillyTavern instance in scope is a no-op, not an error. That is what
  makes it safe to put in a shared home-manager configuration.

The login flow itself — two round trips, a CSRF token and a session cookie —
is in [`users.md`](users.md#scripting-a-login).

## Without a flake

`default.nix` is the non-flake entry point, and it exports the same two
modules, the overlay and the library:

```nix
let
  sillytavern = import (builtins.fetchTarball {
    url = "https://github.com/Cairnstew/SillyTavern/archive/release.tar.gz";
  });
in
{
  imports = [ sillytavern.nixosModules.default ];

  nixpkgs.overlays = [ sillytavern.overlay ];
}
```

`nixosModules.default`, `homeModules.default`, `overlay` and `lib` are the
whole surface. The module still needs a package, and it builds one itself
from the fetched tree — you do not have to pass one.

> `fetchTarball` on a **branch name** follows the branch and is not
> reproducible. Pin a commit instead:
> `https://github.com/Cairnstew/SillyTavern/archive/<commit-sha>.tar.gz`.

## Checking a configuration

```bash
nixos-rebuild dry-activate   # evaluate and show the diff, change nothing
nixos-rebuild                 # build, activate, and start the service
```

`dry-activate` catches the great majority of mistakes, because almost
everything this module does wrong is an evaluation error rather than a
runtime one. The ones it cannot catch are the two silent ones: a `pkgs.…`
package that is not this module's, and a `settings.*` path that upstream does
not have. The first is what the overlay is for — see
[the outputs](#the-outputs); the second is what `settingsExtra.*` and the
`settingsKeysKnown` guard exist for.

After the first activation:

```bash
systemctl status sillytavern
journalctl -u sillytavern -f
```

`docs/troubleshooting.md` maps symptoms to causes.

## Upgrading

```bash
nix flake update sillytavern
nixos-rebuild
```

> ⚠ **Take a copy of the data root before the first boot on a new version.**
> A newer SillyTavern migrates account records and chat files on startup.
> Going *back* to an older version after it has migrated is not supported.
> The data root is the whole state:
>
> ```bash
> sudo -u sillytavern tar -C /var/lib -cf - sillytavern | sudo -u sillytavern \
>   tar -C /backup -xf -
> ```

## Where to go next

| Document | What it answers |
|---|---|
| [`installing.md`](installing.md) | the two decisions that block you: authentication and TLS; where the data lives; reverse proxying; migrating an existing install |
| [`options.md`](options.md) | every option, grouped, with the escape hatch to reach for when the option you want does not exist |
| [`users.md`](users.md) | accounts, permissions, SSO, and how the account database is actually stored |
| [`settings-surface.md`](settings-surface.md) | the UI's own settings: what is Nix-defined, what is session state, and the 439 typed options |
| [`ui-surface.md`](ui-surface.md) | what the front-end reads, and what is deliberately not configurable |
| [`troubleshooting.md`](troubleshooting.md) | symptoms and causes |
| [`CONTRIBUTING.md`](../CONTRIBUTING.md) | how to work on this fork |
