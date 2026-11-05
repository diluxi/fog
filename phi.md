# phi

Notes for LLM agent sessions working on ☁️ (fog), and a handover of where
things stand. On lemma0, every session loads this file through
`~/.claude/CLAUDE.md`.

## The repo

NixOS configuration for lemma0, a Hetzner ccx13. It is flake-free and low on
dependencies on purpose.

- `default.nix` evaluates the system from the inputs in `pins.json`
  (`./fog pin`).
- `lemma/` is the host, `users/` makes accounts from `users/keys.json`, and
  `crypt.nix` decrypts `crypt.secrets` (sop, OpenPGP) into `/run/crypt` at
  activation.
- `fog` is the deploy script, `fog.tofu` the Hetzner infrastructure.
- The canonical remote is github.com/diluxi/fog.

## Identities

- **lux** `<lux@amartia.online>` is the user working with LLMs: the human who
  steers you, and the author of their own commits here. Cert `A405586B…3D3E`.
- **phi** `<phi@amartia.online>` is the LLM agents. There is one cert per
  model; yours is `phi (claude-opus-5-5)`, `4928DFEE…A66C`, vouched for by lux.
  It has one signing subkey per machine: theorem `CD846977E6AC3DB5`, lemma0
  `897676F5…0484E7`. Model settings such as effort do not get identities.

## Commits

- You commit as phi, signed. On lemma0 the git config does this. Never pass
  `--no-gpg-sign`; if signing fails, stop and say so.
- Put the steering human in a trailer:
  `Co-Authored-By: lux <lux@amartia.online>`.
- Subjects start with a sigil: `+` adds, `&` fixes, `%` refactors (and only
  refactors).
- Wrap messages under 80 columns. One concern per commit.
- Evaluate before committing:
  `nix-instantiate . -A config.system.build.toplevel`.

## Style

Tabs in Nix and shell. No flakes, no new dependencies without asking. When
you simplify a design for pragmatic reasons, say so explicitly.

## Deploying

Push your branch and tell lux. Until fog-deploy is live, lux deploys with
`./fog deploy test`, then `switch`. After that, a lux-signed tip of dev is
switched to and a phi-signed one tested; `fog pull` on lemma0 deploys now
instead of within five minutes, and `fog ratify` (wheel) keeps a test.

## Handover (2026-11-05)

### Done

- Bugs fixed in `crypt.nix`, the firewall (`trustedInterfaces` for fog),
  `fog`'s sync and activation, and `users/fetch`.
- nixpkgs moved to nixos-unstable (26.11pre) and deployed.
- The lux user (wheel, OpenPGP auth subkey plus a phone key) and the phi user
  (no groups, lingering) exist.
- `phi-foreign`, a user service for phi, clones this repo to `~/fog`, sets up
  the push and signing keys, and runs `claude remote-control`.

### In review

- `phi/fog-deploy`: fog-deploy (`lemma/deploy.nix`) and lemma0's `fog`
  command (`fog ratify`, `fog pull`). Before it can switch, lux adds a cert
  to its switch tier; phi's cert there lacks the theorem subkey. Its root is
  the dev tip it branched from; if dev is rewritten, update it.

### Next, as agreed

1. LLDAP and Authelia (`lemma/id.nix` is an unimported stub),
   Vaultwarden, Stalwart (the `coop` branch; move its hardcoded
   `fallback-admin` secret into `crypt.secrets` first), and the webpages as
   nix-built per-site profiles instead of rsync.

### Open issues

- fog WireGuard: lemma0's `fc00:0010::10` collides with peer yui's
  AllowedIPs, and the `thm//` peer at `10.0.0.1` is unidentified. lemma0's
  public key is `fog++kDxd3oYo4t280RM1HmxpaU/T1ibRKD5hOEJ8DE=`.
- sshd stays public until fog WireGuard works end to end; then bind it to fog.
- Jellyfin migrates its database one way on nixpkgs bumps; back up first.
- `phi-foreign` hasn't been tested without a terminal. If `claude
  remote-control` needs one, wrap it in `script -qfec … /dev/null`.

### Gotchas

- Sequoia judges validity at the signature's creation time. lux must vouch for
  a new agent cert before its first signature, or those signatures stay `U`.
- gpg-sq (the Chameleon) takes trust roots from `pubring.cert.d`'s trust-root
  links, not from ownertrust, and its `--import` corrupts unprotected secret
  keys. Import those with GnuPG's `gpg`.
- git rejects commits with more than one signature. Co-signing means a signed
  merge or tag on top.
- On theorem, gpg-agent shows one pinentry at a time. A signing prompt for lux
  blocks the user's pass lookups, which is why lux has its own agent unlocked
  with `lux-unlock`.
