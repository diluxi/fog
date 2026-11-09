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

dev stays linear: no merge commits. Branch from `origin/dev`, push your
`phi/<topic>` branch and tell lux. Several topics in a row go on one stack,
each branched from the last, so that each can still be fast-forwarded. lux
lands it like this:

```sh
git fetch origin
git switch dev && git merge --ff-only origin/phi/<topic> && git push origin dev
git push origin --delete phi/<topic>
```

Your commits keep your signature, so the commit log shows which model wrote
them. fog-deploy (`lemma/deploy.nix`, every five minutes) only tests a
phi-signed tip; it becomes the boot default when a wheel user runs
`fog ratify` on lemma0, or when lux signs a commit on top (a secret, say),
which is switched to. `fog pull` deploys right away.

A branch that waits for a secret throws at evaluation (`todo`) until lux
commits the secret on top of it, so put it last in a stack.

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
  `sqop encrypt lemma/certs/lemma0.asc lemma/certs/lux.asc`. Only what must
  survive a reinstall goes there (lldap's key_seed, authelia's storage key,
  passwords lux chose). Service internals are `crypt.generated`: made once
  on lemma0 in /var/lib/crypt, and read there to break glass. lux doesn't
  want them in a password manager.
- LLDAP and Authelia (`lemma/id.nix`): auth.amartia.online, and
  ldap.amartia.online for lldap_admin with a second factor. root is the
  declarative break-glass account. Services bind as their own accounts,
  declared with `lldap.serviceAccounts` (`lemma/lldap-accounts.nix`), which
  creates them, adds their groups and sets generated passwords.
- Stalwart (`lemma/mail.nix`) on mx.amartia.online for amartia.online and
  cpli.dev, with autoconfig. Accounts come from LLDAP, aliases from the table
  in `mail.nix`. SPF, DKIM, DMARC and rDNS pass.
- `crypt.secrets.<name>.services` restarts the services that read a secret
  when it changes.
- ecdo (`lemma/ecdo.nix`) publishes websites at runtime. Each host is a nix
  profile in `/var/lib/ecdo/sites/<host>/site`, which caddy serves with one
  catch-all rule and on-demand certificates. `./fog publish <site> <dir>`
  signs `ecdo <site>\n` plus the tarball and sends both over ssh to the
  `ecdo` user, whose keys are lux's and locked to the ecdo command. lux's
  signature publishes to `<site>`, yours to `preview.<site>`; lux promotes a
  preview by publishing the same tree, which lands on the same store path.
  You sign with `FOG_GPG=gpg-phi FOG_KEY='CD846977E6AC3DB5!'` on theorem.
  `./fog sites` lists, `./fog sites rollback <host>` rolls back.
  `ecdo.certified` hosts get a vhost of their own, so their certificate
  always exists at a fixed path for other services to reuse.
- ejabberd (`lemma/xmpp.nix`) serves amartia.online to the lldap group
  `xmpp`: state in sqlite, conference/pubsub/upload components, certificates
  from caddy, and FAST tokens, since LDAP auth only allows PLAIN and
  Conversations requires channel binding.
- transmission (`lemma/torrent.nix`) on torrent.amartia.online for the lldap
  group `torrent`, inside a network namespace whose only way out is
  mullvad's wireguard. The secret is only the account number; lemma0
  registers its own key and picks relays at runtime, narrowed by
  `/var/lib/mullvad/prefer`. `systemctl start mullvad-switch` changes relay.
- Invitations (`lemma/invite.nix`, Go in `lemma/invite/`): lldap_admin
  makes single-use links at invite.amartia.online/new for groups that
  modules declare in `invite.groups`; the invitee picks a username, a
  contact address and a password. Mail and xmpp are groups now (`mail`,
  `xmpp`); a mail user's address is the lldap attribute `mailbox`, and
  lldap's `mail` is their contact address. `invite-migrate` moved everyone
  already there into those groups once (stamp in /var/lib/invite).

### Next, as agreed

1. DNS at Hetzner (`fog.tofu`): both zones and rDNS, then the nameservers
   at Namecheap.
2. Grafana (Prometheus, node-exporter) with OIDC through Authelia.
3. kino (Jellyfin) to amartia.online, with SSO through its OIDC or LDAP
   plugin; forward_auth would lock out the TV and phone apps.
4. vaultwarden SSO through Authelia, gated by a `vault` group, so
   invitations can give a vault too.
5. Authelia's notifier through Stalwart, so password-reset mail is sent
   instead of written to a file.

### Later

- Bulwark's Lite build (static JMAP webmail) behind Authelia.
- A web frontend for `crypt.secrets`, so secrets can be generated with
  Bitwarden's generator instead of on the command line.

### Open issues

- Mail deliverability: Barracuda lists 91.98.239.136 (delist at
  barracudacentral.org); Google Postmaster Tools and Microsoft SNDS/JMRP
  are not set up.
- Stalwart's web admin has its own login. Its OIDC directory takes only
  bearer tokens, which would end password logins for IMAP clients; at most
  Authelia can guard `/admin` in front of it.
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
- git rejects commits with more than one signature, so lux doesn't rebase
  your commits (that would replace your signature). Never amend or rewrite
  a commit lemma0 has deployed: fog-deploy refuses a tip that doesn't
  descend from `/var/lib/fog-deploy/switched`.
- Stalwart's `%{file:}%` doesn't trim, so its secrets need no trailing
  newline. A name with any record of its own hides the DNS wildcard.
- Some nixpkgs changes are switch inhibitors and need a reboot (the
  dbus-broker change was one). `fog ratify` first: a reboot drops anything
  only tested.
- On theorem, gpg-agent shows one pinentry at a time. A signing prompt for lux
  blocks the user's pass lookups, which is why lux has its own agent unlocked
  with `lux-unlock`.
