# Users

Accounts, how they are seeded, and what happens when you get one wrong.

- [Declaring accounts](#declaring-accounts)
- [Passwords](#passwords)
- [The empty-password trap](#the-empty-password-trap)
- [How seeding works](#how-seeding-works)
- [Provider API keys](#provider-api-keys)
- [What the seeder writes](#what-the-seeder-writes)
- [Scripting a login](#scripting-a-login)
- [SSO](#sso)

---

## Declaring accounts

The attribute name is the account **handle**, which is also its directory name
under the data root and the lowercased username an SSO provider must send.

```nix
services.sillytavern-nixos = {
  config.enableUserAccounts = true;

  users.seanc = {
    name = "Sean";                                       # display name; defaults to the handle
    passwordFile = config.age.secrets.sillytavern-seanc.path;
    admin = true;
  };

  users.reader = {
    passwordFile = config.age.secrets.sillytavern-reader.path;
  };

  users.guest = { };                                     # no passwordFile — see below
};
```

| Option | Default | |
|---|---|---|
| `name` | the handle | Display name in the UI. Also what the account's `handle` falls back to. |
| `passwordFile` | `null` | File holding the plaintext password. Read at activation, then scrypt-hashed. |
| `admin` | `false` | Whether the account may manage other accounts. |
| `enabled` | `true` | Whether the account can log in at all. |

`users` requires `config.enableUserAccounts = true`, and the module asserts both
directions: declaring accounts without enabling them is meaningless, and
enabling them is what activates `default-user`.

## Passwords

Always a **file**, never a literal:

```nix
users.seanc.passwordFile = config.age.secrets.sillytavern-seanc.path;
```

The value is read at service start from a path you control (an agenix
decryption, a systemd credential, anything readable by the service account) and
scrypt-hashed into the account database. The plaintext never enters the Nix
store, the unit file, or `ps` output. The command line the seeder receives
carries the *path*, not the contents — see `mkUserArg` in `lib/default.nix`.

Trailing newlines and CRLF are stripped; leading and trailing **spaces are not**,
because they can be legitimate in a passphrase and silently eating them is worse
than failing. An interior newline is rejected by an assertion: systemd's
`EnvironmentFile=` parser ends a value at a newline even inside quotes, which
would truncate the value with no error anywhere.

## The empty-password trap

This is the one thing to be careful about. An account declared **without** a
`passwordFile` gets an empty password, and in SillyTavern an empty password means
**passwordless**, not disabled. The login check is:

```js
// src/endpoints/users-public.js
if (user.password && user.password !== getPasswordHash(request.body.password, user.salt)) { … }
```

An empty stored password fails that test, so the comparison is **skipped
entirely** and login succeeds with any password at all.

The module refuses this combination unless you acknowledge it:

```nix
services.sillytavern-nixos.allowPasswordlessUsers = true;
```

Set that only when every passwordless account is protected by
`config.sso.autheliaAuth`, `config.sso.authentikAuth`, or
`config.enableDiscreetLogin` on a network you trust. Note that discreet login
only hides the user *list*; it does not authenticate anybody.

`default-user` is the built-in exception, and the module will not let you
redeclare it: the server creates it itself on first start, with `admin: true` and
an empty password. Declaring it here would be silently ignored by the idempotent
seeder, leaving you with an administrator whose password nobody chose — and a
configuration that reads as if it does not.

## How seeding works

`scripts/st_seed_users.py` runs in the unit's `preStart`, before the server
starts, so a fresh state directory already has its accounts on the first login.

**Seeding is create-only and idempotent.** A handle that already exists is left
completely alone — so a password changed through the UI survives the next
`nixos-rebuild`. To rotate one, delete the account (or the whole
`_storage/<digest>` file) and rebuild, or change it in the UI and stop managing
it by removing the handle from `users`.

Removing a handle from `users` **stops managing it**; it does not delete the
account or its data.

## Provider API keys

Since 1.19 every provider key lives in a per-account `secrets.json` rather than
in `settings.json`, shaped so a key can be rotated without losing the old one:

```json
{ "api_key_openai": [ { "id": "…", "value": "…", "label": "personal", "active": true } ] }
```

Only the `active` entry is sent upstream. There is no way to set one through
`files`, and putting it in `settings.json` does not work — the server no longer
reads it there. `secrets.byUser` is the only route:

```nix
services.sillytavern-nixos.secrets.byUser = {
  seanc = {
    api_key_openai.value = config.age.secrets.openai-api-key.path;
    api_key_claude = {
      value = config.age.secrets.anthropic-api-key.path;
      label = "work";
    };
  };
};
```

- `value` is a **path**, never the key. A literal would be copied into the Nix
  store, which is world-readable.
- `label` defaults to the key name and is what the UI's key manager shows.
- The spec rendered into the store carries **paths only**; the bytes are read at
  activation, so a key never appears in `nixos-rebuild` output, a crash log, or
  `nix eval`.

Merging is idempotent and does not fight the UI: a key already active with this
value is left alone, and under the default `seedPolicy = "missing"` a key you
added through the UI is never overridden. Under `"overwrite"` the previously
active entry is *deactivated*, not deleted, so the UI's key history keeps
working.

The key names are SillyTavern's own `SECRET_KEYS` table in
`public/scripts/secrets.js` — `api_key_openai`, `api_key_claude`,
`api_key_novel`, and roughly twenty more.

## What the seeder writes

SillyTavern does **not** store accounts in a JSON file. `src/users.js`
initialises a [node-persist](https://www.npmjs.com/package/node-persist) store at
`$DATA_ROOT/_storage`, and each datum is one file named by the hex sha256 of its
key:

```
$DATA_ROOT/_storage/<sha256hex("user:seanc")>
  →  {"key":"user:seanc","value":{…},"ttl":null}
```

The account key is `user:<handle>` (`KEY_PREFIX = 'user:'`). Verified against
node-persist 4.0.4, where `getDatumPath` is
`path.join(dir, sha256(key))` with
`sha256 = crypto.createHash('sha256').update(key).digest('hex')`.

That is why `scripts/st_seed_files.py` **refuses** `_storage/` outright: writing
that database as JSON would corrupt it. `lib/userKeyFor` in `lib/default.nix`
builds the key; the digest itself is computed in Python, because Nix has no
sha256 over strings without going through a derivation, and the seeder needs the
same digest anyway.

## Scripting a login

The Home Manager module can write a `sillytavern-login` script, but it needs a
`loginCommand` you supply. It is a string rather than something the module
builds because a login is **two round trips**: you need a CSRF token and a
session cookie before anything else works.

```nix
sillytavern = {
  enable = true;
  accounts = [ "seanc" ];
  loginScript = true;
  url = "https://st.example.com";

  # `curl` and `jq` are on PATH via `loginPackages`, which defaults to both.
  loginCommand = ''
    jar=$(mktemp)
    token=$(curl --fail-with-body --silent --show-error \
      --cookie-jar "$jar" --cookie "$jar" \
      "$SILLYTAVERN_URL/csrf-token" | jq -r .token)
    curl --fail-with-body --silent --show-error \
      --cookie-jar "$jar" --cookie "$jar" \
      --header "X-CSRF-Token: $token" \
      --header 'Content-Type: application/json' \
      --data "{\"handle\":\"$ACCOUNT\",\"password\":\"$(cat \"$PASSWORD_FILE\")\"}" \
      "$SILLYTAVERN_URL/api/users/login"
    rm -f "$jar"
  '';

  # Anything else your command shells out to:
  # loginPackages = with pkgs; [ curl jq coreutils ];
};
```

> **Use `$ACCOUNT` and `$SILLYTAVERN_URL`, not Nix interpolation.** The generated
> script exports `ACCOUNT`, `SILLYTAVERN_URL` and `SILLYTAVERN_HOST` before
> running `loginCommand`, and those are the whole contract. They are *shell*
> variables: a Nix string is evaluated in the scope where you wrote it, where
> `ACCOUNT` is not bound, so writing `"${ACCOUNT}"` fails at evaluation with
> `undefined variable 'ACCOUNT'`. The same trap catches a half-written version
> that interpolates the sibling option `url` — a Nix attribute set is not
> recursive, so `url = …;` does not put `url` in scope on the next line either.
>
> `PASSWORD_FILE` is **yours** to set; the module has no opinion about where
> passwords live and deliberately ships none. Export it from your own
> `loginCommand` wrapper, or read it from a path you control.

> The password belongs in a file you control, not in this string. A login
> script is a shell script on disk; `sillytavern.loginCommand` is your own
> business, and the module deliberately does not know about passwords — see the
> note on `accounts` in `modules/home.nix`.

The flow, from the server side:

| Step | Request | Notes |
|---|---|---|
| 1 | `GET /csrf-token` | Returns `{ "token": "…" }` and sets the session cookie (`src/server-main.js:192`). |
| 2 | `POST /api/users/login` | Body `{ "handle", "password" }`, header `X-CSRF-Token: <token>`, **keeping the cookie**. Returns `{ "handle": "…" }`. |

The token is read from the `X-CSRF-Token` request header
(`getTokenFromRequest`, `src/server-main.js:180`) and must be the one tied to the
session cookie from step 1. Skip the cookie and step 2 fails with
`ForbiddenError: Invalid CSRF token`.

After a successful login the session carries `handle` and `version`; `version` is
checked on every request, so changing an account invalidates its live sessions.

## SSO

```nix
services.sillytavern-nixos.config = {
  enableUserAccounts = true;
  sso = {
    autheliaAuth = true;          # trusts Authelia's Remote-User header
    authentikAuth = true;         # trusts authentik's forwarded-identity header
    trustedProxies = [ "127.0.0.1" "192.168.1.1" ];
  };
};
```

`trustedProxies` is a genuine authentication boundary: an address in that list
can assert who anybody is. `["*"]` trusts everything, and upstream marks it NOT
RECOMMENDED. It must cover the proxy's address and nothing else — which is why
SSO and `enableForwardedWhitelist` want the same care.
