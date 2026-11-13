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
  AirVPN's WireGuard (Mullvad until 2026-11, which forwards no ports). The
  secrets are the device's wg-quick config from AirVPN's generator and the
  account's forwarded port, which becomes Transmission's peer port. Every
  AirVPN server shares one key, so lemma0 picks a server's endpoint at
  runtime from the public status API, least loaded first, narrowed by
  `/var/lib/airvpn/prefer` (names, country codes or cities).
  `systemctl start airvpn-switch` moves to another server. Prowlarr runs
  in the same namespace (trackers see one address for searching and
  announcing) at prowlarr.amartia.online for `torrent`, its own login off
  (Authelia's), its API key generated (`crypt.generated.prowlarr-api`) and
  reachable on the host at 127.0.0.1:9697. `prowlarr-clients` declares
  Transmission (127.0.0.1:9091 from inside) as its download client through
  that API; a release's category picks its directory under /srv/seed
  (video, audio, books, else other).
- Invitations (`lemma/invite.nix`, Go in `lemma/invite/`): lldap_admin
  makes single-use links at invite.amartia.online/new for groups that
  modules declare in `invite.groups`; the invitee picks a username, a
  contact address and a password. Mail and xmpp are groups now (`mail`,
  `xmpp`); a mail user's address is the lldap attribute `mailbox`, and
  lldap's `mail` is their contact address. `invite-migrate` moved everyone
  already there into those groups once (stamp in /var/lib/invite).
- `fog` (`lemma/mail.nix`) is the system's own address, fog@amartia.online:
  an lldap service account in `mail`, and postmaster@, abuse@ and root@
  amartia.online are its aliases, so domain reports land there and not in
  lux's personal mailbox. Authelia sends password resets and one-time codes
  as fog, through Stalwart's submission on loopback.
- Storage: witness0, a Hetzner storage box (`fog.tofu`, bx21 in fsn1),
  mounted over SMB 3.1.1 by its `srv` subaccount (`lemma/box.nix`). Tofu
  generates both passwords; `./fog witness` writes the mount's server and
  the encrypted credentials to `lemma/witness0.{json,asc}`, and once the
  gocryptfs key, `lemma/witness0-key.asc`: everything on the box is
  encrypted (names and contents; sizes show), each tree its own gocryptfs
  directory under srv/cipher/, mounted root-only at /var/lib/witness0/<tree>
  and decrypted at: `/srv/seed`, what transmission seeds, sorted by kind;
  `/srv/seed/video`, what kino may link to; `/srv/kino`, Jellyfin's
  libraries, mostly symlinks into seed/video (`mfsymlinks`). Partial
  torrents stay in /var/lib. Losing the key loses the box.
- VPN (`lemma/vpn.nix`): wg-portal at vpn.amartia.online, logins only
  through Authelia's OIDC with a second factor. Each `vpn.roles.<name>` is
  a WireGuard interface `fog-<name>` that wg-portal owns with its peers,
  on port 51820+n, in 10.10.n.0/24 and fd60:d315:194a:n::/64 (lemma0 is .1
  and ::1). Who may add peers to it is an lldap group (wg-portal's LDAP
  sync, which logs nobody in); what the peers reach is the firewall by
  interface (`trusted`, `tcp`). `wg-portal-roles` declares the interfaces
  through wg-portal's API, with keys from `crypt.generated.vpn-fog-<name>`.
  Roles: `admin` (lldap_admin, everything) and `torrent` (the RPC on 9092,
  for Tremotesf). `fog` and `dn42` stay networkd's.
- odos (`lemma/odos.nix`, Common Lisp in `lemma/odos/`), "way" in Greek:
  links what's under `/srv/seed/video` into Jellyfin's two libraries,
  `/srv/kino/TV/Show (Year)/Season NN/Show SxxEyy.ext` and
  `/srv/kino/Films/Title (Year)/Title (Year).ext`, subtitles beside their
  video, by what guessit (run as a CLI, one call per run) makes of the
  names. Shows and films are identified through Jellyfin's remote search
  (TMDb) and their folders named `Name (Year) [tmdbid-N]`, so one show under
  two titles (Sousou no Frieren, Frieren: Beyond Journey's End) is one
  folder; lookups are kept in `/var/lib/odos/ids`, and while Jellyfin is
  away, unidentified files wait for the next run. `S01E01v2` loses its `v2`
  before guessit reads it, since guessit would read a film otherwise.
  Where no name says enough (Monogatari: one TMDb show whose arcs are
  seasons and extras, Kizumonogatari three films), `odos.rules` in
  `lemma/odos-rules.nix` says it: a path under the seed tree is a TMDb film,
  or a show whose files' episode n is episode n+offset of a season, by
  ranges; a range with `parts` is the parts of one episode
  (`S04E01 - part1`, `- part2`), which Jellyfin plays as one. Folder ordinals (`14. Owarimonogatari`) go before guessit reads.
  Only files nothing under `/srv/kino` links to are read, so hand-made
  links stand. Links whose file is gone are removed. What it can't place
  surely (no season, a place taken by a file) is listed in
  `/var/lib/odos/unsure`. Where two copies of the same episode or film are
  seeded, the better one is linked, by what ffprobe reads (guessit doesn't
  know AV1): resolution tier, then codec (av1 > hevc > vp9 > h264 > vc1 >
  mpeg), bit depth, HDR, and with all that equal, the video's bit rate over
  the same 30 s of both, which must win by more than a sixth. The losers
  are recorded in `/var/lib/odos/seconds` and not read again while the
  winner stays linked; if it goes, they compete again.
  Runs on Transmission's done-hook (a marker in `/run/odos`, through a path
  unit), daily, and by hand with `systemctl start odos`; `odos --dry-run`
  shows what it would do. It tells Jellyfin which folders changed with the
  generated key `crypt.generated.jellyfin-api`, which kino's pre-start
  writes into Jellyfin's `ApiKeys` as `odos`.
- soju (`lemma/irc.nix`): an IRC bouncer at irc.amartia.online:6697 (TLS,
  caddy's certificate, copied in and reloaded on renewal) for the lldap
  group `irc`. soju's `auth http` asks a loopback Caddy site, which asks
  Authelia's `basic` authz endpoint for irc's rule; a first login makes the
  soju user. One factor, like xmpp. Naming that endpoint drops Authelia's
  defaults, so `id.nix` names `forward-auth` too. History is soju's sqlite,
  expiring after a year.

### Next, as agreed

1. DNS at Hetzner (`fog.tofu`): both zones and rDNS, then the nameservers
   at Namecheap.
2. Grafana (Prometheus, node-exporter) with OIDC through Authelia.
3. kino (Jellyfin) to amartia.online, with SSO through its OIDC or LDAP
   plugin; forward_auth would lock out the TV and phone apps.
4. vaultwarden SSO through Authelia, gated by a `vault` group, so
   invitations can give a vault too.

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
- The firewall is nftables, and it filters forwarding: only fog to fog
  passes. Anything else lemma0 should route (dn42, more WireGuard
  interfaces) needs its own `firewall.extraForwardRules`.
- On theorem, gpg-agent shows one pinentry at a time. A signing prompt for lux
  blocks the user's pass lookups, which is why lux has its own agent unlocked
  with `lux-unlock`.
