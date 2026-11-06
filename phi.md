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
  `Co-Authored-By: lux <lux@amartia.online>`. Never add a trailer for the
  model (no `Co-Authored-By: Claude …`): your signing cert already names it.
- Work on `phi/<topic>` branches, never on dev directly.
- Subjects start with a sigil: `+` adds, `&` fixes, `%` refactors (and only
  refactors).
- Wrap messages under 80 columns. One concern per commit.
- Evaluate before committing:
  `nix-instantiate . -A config.system.build.toplevel`.

## Style

Tabs in Nix and shell. No flakes, no new dependencies without asking. When
you simplify a design for pragmatic reasons, say so explicitly.

## Deploying

dev stays linear: no merge commits. Push your `phi/<topic>` branch and tell
lux, who lands it like this:

```sh
git fetch origin
git rebase origin/dev phi/<topic>    # re-signs every commit as lux
git switch dev && git merge --ff-only phi/<topic> && git push origin dev
git push origin --delete phi/<topic>
```

The rebase makes lux the committer and signer of each commit; you stay the
author. So the tip of dev is lux-signed, and fog-deploy (`lemma/deploy.nix`,
every five minutes) switches to it. A phi-signed tip is only tested, until a
wheel user runs `fog ratify` on lemma0. `fog pull` deploys right away.

Don't push to dev, and never rewrite or force-push it, unless lux asks.
fog-deploy refuses any tip that doesn't descend from the last commit it
switched to, so a rewrite stops deploys until its state is fixed by hand.

## Handover (2026-11-06)

### Done

- Bugs fixed in `crypt.nix`, the firewall (`trustedInterfaces` for fog),
  `fog`'s sync and activation, and `users/fetch`.
- nixpkgs on nixos-unstable (26.11pre), dbus-broker after a reboot.
- Users: lux (wheel, OpenPGP auth subkey plus a phone key) and phi (no
  groups, lingering).
- `phi-foreign` runs `claude remote-control` for phi in `~/fog`.
- fog-deploy and `fog ratify` deploy signed commits from dev.
- crypt: lemma0 decrypts with its own host cert, `lemma/certs/lemma0.asc`.
  Encrypt new secrets with
  `sqop encrypt lemma/certs/lemma0.asc lemma/certs/lux.asc`.
- LLDAP and Authelia (`lemma/id.nix`): auth.amartia.online, and
  ldap.amartia.online for lldap_admin with a second factor.

### Next, as agreed

1. Vaultwarden (`phi/vaultwarden`).
2. Stalwart (the `coop` branch; move its hardcoded `fallback-admin` secret
   into `crypt.secrets` first).
3. The webpages as nix-built per-site profiles instead of rsync.
4. Invite codes for new users, against LLDAP's GraphQL API.

### Open issues

- Authelia binds to LLDAP as admin. A service account in
  `lldap_password_manager` would be tighter.
- fog WireGuard: lemma0's `fc00:0010::10` collides with peer yui's
  AllowedIPs, and the `thm//` peer at `10.0.0.1` is unidentified. lemma0's
  public key is `fog++kDxd3oYo4t280RM1HmxpaU/T1ibRKD5hOEJ8DE=`.
- sshd stays public until fog WireGuard works end to end; then bind it to fog.
- Jellyfin migrates its database one way on nixpkgs bumps; back up first.

### Gotchas

- Sequoia judges validity at the signature's creation time. lux must vouch for
  a new agent cert before its first signature, or those signatures stay `U`.
- gpg-sq (the Chameleon) takes trust roots from `pubring.cert.d`'s trust-root
  links, not from ownertrust, and its `--import` corrupts unprotected secret
  keys. Import those with GnuPG's `gpg`.
- git rejects commits with more than one signature. On dev, lux's signature
  replaces yours when lux rebases; your authorship stays.
- Some nixpkgs changes are switch inhibitors and need a reboot (the
  dbus-broker change was one). `fog ratify` first: a reboot drops anything
  only tested.
- On theorem, gpg-agent shows one pinentry at a time. A signing prompt for lux
  blocks the user's pass lookups, which is why lux has its own agent unlocked
  with `lux-unlock`.
