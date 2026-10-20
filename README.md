# SillyTavern

LLM Frontend for Power Users — packaged for NixOS, with every part of the
server's configuration expressible in Nix.

> **This is a fork.** The application is upstream SillyTavern; the Nix
> packaging, the `services.sillytavern-nixos` module and everything under
> `modules/`, `lib/`, `pkgs/` and `docs/` are this repository's.

## Using it

```nix
{
  inputs.sillytavern.url = "github:Cairnstew/SillyTavern";

  outputs = { nixpkgs, sillytavern, ... }: {
    nixosConfigurations.laptop = nixpkgs.lib.nixosSystem {
      modules = [
        sillytavern.nixosModules.sillytavern
        {
          nixpkgs.overlays = [ sillytavern.overlays.default ];
          services.sillytavern-nixos = {
            enable = true;
            config.enableUserAccounts = true;
            users.seanc = { name = "Sean"; admin = true; passwordFile = /run/keys/st; };
          };
        }
      ];
    };
  };
}
```

Nothing else is required: the module supplies its own package, renders
`config.yaml` into the Nix store, creates the data root, seeds accounts and
JSON state at activation, and installs a hardened systemd unit that starts at
boot.

**[docs/getting-started.md](docs/getting-started.md)** is the full guide:
pinning, the flake's outputs, the Home Manager half, and the two decisions
that will otherwise block you.

## What Nix can drive

| | |
|---|---|
| **Every `config.yaml` key** | modelled one-for-one, with a round-trip check against upstream's own document |
| **Every CLI flag** (31) | `services.sillytavern-nixos.cli.*` |
| **Every `SILLYTAVERN_*` env var** | plus `environment` / `extraConfigEnv` for the rest |
| **Every named profile** | `services.sillytavern-nixos.presets.*` — the presets, templates, themes, lorebooks and quick-reply sets, by name |
| **Provider API keys** | `secrets.byUser`, read from files so they never reach the store |
| **Per-account state** | `settings.*`, `files.*` — presets, themes, lorebooks, quick replies, per-user extensions |
| **The UI stylesheet** | `customCss` |
| **Branded error pages** | `errorPages.*` |
| **Plugins and extensions** | `plugins` / `extensions`, pinned by `rev` |
| **TLS** | `ssl.certFile` / `ssl.keyFile`, copied in at build time |
| **The unit** | `systemdOverrides`, `hardware` caps, `restartTriggers` |
| **A reverse proxy** | `proxyUpstreams` carries the four settings that proxy setups get wrong |

## Documentation

- **[docs/getting-started.md](docs/getting-started.md)** — using this as a flake
  input: adding it, pinning it, the outputs, the module, the Home Manager half
- **[docs/installing.md](docs/installing.md)** — the decisions that block you:
  authentication and TLS; where the data lives; reverse proxying
- **[docs/options.md](docs/options.md)** — the option surface
- **[docs/users.md](docs/users.md)** — accounts, permissions, scripting a login
- **[docs/settings-surface.md](docs/settings-surface.md)** — the UI's own
  settings, and the 410 typed options that cover them
- **[docs/troubleshooting.md](docs/troubleshooting.md)** — symptoms and causes
- **[docs/ui-surface.md](docs/ui-surface.md)** — what the front-end reads, and
  what is deliberately not configurable
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — how to work on this fork

## Development

```bash
nix develop                  # nodejs, npm, python3, pytest
npm ci                       # the app's dependencies
nix flake check              # the whole suite
python3 -m pytest nix-tests/ # the seeder's tests
./nix-tests/home-eval.sh     # the Home Manager module (needs network)
nix run .                    # a server straight from the store
```

## Upstream

- GitHub: <https://github.com/SillyTavern/SillyTavern>
- Docs: <https://docs.sillytavern.app/>
- Discord: <https://discord.gg/sillytavern>

## License

AGPL-3.0