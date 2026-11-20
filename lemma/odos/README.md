# odos

"Way" in Greek: the way from a torrent to a library. odos links what
qBittorrent seeds into Jellyfin's and Kavita's libraries:

- videos under `/srv/seed/video` go to
  `/srv/kino/TV/Show (Year) [tmdbid-N]/Season 02/Show S02E05.mkv` and
  `/srv/kino/Films/Title (Year) [tmdbid-N]/Title (Year) [tmdbid-N].mkv`;
- the shelf's files under `/srv/seed/{manga,comics,books}` go to
  `/srv/shelf/{Manga,Comics,Books}/<Series>/<file>`.

The module is `../odos.nix`, and the rules from Nix are `../odos-rules.nix`.
`phi.md` describes odos from the outside; this file describes its inside.

## A run

`odos` in `run.lisp` does the following, holding the lock:

1. **setup**: read Jellyfin's key, the TMDb cache (`ids`) and the rules
   (Nix's and the command line's).
2. **survey** (`links.lisp`): walk every link under the link roots and
   collect the set of targets, removing links whose file is gone.
3. **candidates**: find the videos, subtitles and shelf files that nothing
   links to. Files kept out as seconds and files that rules ignore are
   dropped here.
4. **link-all**: run guessit once over all of them (`guessit.lisp`), on
   the path relative to the video tree and on the file's name alone. Then
   `place` each video (`place.lisp`): a rule if one holds it (`rules.lisp`),
   otherwise the titles read, looked up at TMDb (`tmdb.lisp`). `put-video`
   then links it, or compares it with the copy already linked there
   (`copies.lisp`: a rule's preference first, then ffprobe). Subtitles
   follow their video's place last.
5. **link-shelf** (`shelf.lisp`): each shelf file goes to its series
   folder, keeping its name.
6. **write state** (`state.lisp`): `ids`, `seconds`, `unsure`. Then tell
   Jellyfin which folders changed, or keep them in `pending` if Jellyfin
   doesn't answer.

A file is read only while nothing links to it. Everything else follows
from that: hand-made links stand, a run costs little, and placing a file
again means unlinking it.

## Files, in load order

`odos.asd` is `:serial t`. Each file compiles with only the macros and
specials defined above it.

| file | what it holds |
|---|---|
| `package.lisp` | the package; the specials set by flags (`*video*`, `*links*`, `*shows*`, `*films*`, `*state*`, `*shelves*`, `*dry-run*`, …); the extension lists; `say`, `number-in` |
| `files.lisp` | string paths (`join`, `dirname`, `under`, `relative`, `normalize`); `kind`, `entries`, `walk`, `prune` through sb-posix; `read-pairs`/`write-lines` (atomic, handed back to the state's owner when written as root); `lock`/`with-lock` (flock on `*state*`) |
| `guessit.lisp` | `readable` (drops `v2`, folder ordinals); `guess` (one guessit call for many names); `field`, `fields` |
| `tmdb.lisp` | `jellyfin` (curl, config on stdin, so the key stays off the command line); `remote-search`, `look-up`, `identify` with the `*ids*` cache (hits kept for good, misses for `+retry+`) |
| `rules.lisp` | rule forms; `read-rules` (`*nix-rules*`, `*cli-rules*`, `*rules*`); `holds`, `longest-rule`, `rule-for`, `ignored`, `preference` |
| `place.lisp` | folder names (`clean`, `fold`, `folders`, `folder`, `known-folder`); `place-by-rule`, `place`, `reads-as`, `titles` |
| `copies.lisp` | `probe`, `bit-rate`, `better` (ffprobe); `wins` (preference, then `better`) |
| `links.lisp` | `target`, `link-roots`, `survey`, `candidates` |
| `run.lisp` | `run` struct (counts, unsure, planned links for dry runs); `put`, `put-video`, `link-all`, `unless-failing`; `setup`, `odos`, `pass` |
| `state.lisp` | `pending`, `seconds` (`settled`), `report` to Jellyfin |
| `shelf.lisp` | `series-name`, `shelf-series`, `link-shelf` |
| `change.lisp` | for the command line: `all-links`, `absolute`, `rule-path`; `unlink-under`; `change` (add a rule, unlink, `rerun`); `rerun` (systemctl start, then the run's journal) |
| `commands.lisp` | `cmd-*`: `show`/`film`/`episode`, `series`, `ignore`, `prefer`, `forget`, `relink`, `list`, `unsure`, `rules [--nix]`, `search` |
| `resolve.lisp` | `cmd-resolve`: the steps of `place` and `put-video` for one path, saying each |
| `main.lisp` | `usage`, `+flags+`, `command` (dispatch), `main` |

## State, in `*state*` (`/var/lib/odos`, really `/var/lib/private/odos`)

| file | lines | written by |
|---|---|---|
| `ids` | `kind\|title\|year` or `kind\|tmdb:N`, then id, name, year; or `-` and the time of the miss | runs |
| `seconds` | copy, place, video: a copy kept out while another is linked at its place | runs; the command line forgets entries |
| `unsure` | why, path: what the last run left alone | runs |
| `pending` | update type, folder: what Jellyfin hasn't heard yet | runs; the command line adds `Deleted` |
| `rules` | the command line's rules, as s-expressions | the command line |

## Rules

```lisp
(path :film id)
(path :show id)                                     ; seasons as the names say
(path :show id :episodes ((from to season offset parts) ...))
(path :show id :episode (season number))            ; one file
(path :series "Name")                               ; a shelf's
(path :ignore t)
(path :prefer t)                                    ; goes with any of the above
```

A video's path is relative to the video tree. A shelf's path is relative to
the seed tree and starts with its tree's name (`manga/…`).

The rule for a file is the longest path that holds it. A path holds the
file itself, anything in a folder below it, and, if the path is a video,
the subtitles beside it.

Placement (`rule-for`) and preference (`preference`) are looked up
separately. So a `:prefer` rule never hides where a file goes. Of two rules
with equally long paths, the command line's wins. Nix renders `odos.rules`
in `../odos.nix`, and `nix-rule` in `commands.lisp` turns forms back into
Nix. Both must learn any new key.

## The command line

The wrapper in `../odos.nix` runs as root. It passes the service's flags
plus `--key-file` and `--service odos.service`.

The command line never makes links itself, because root's links and
folders would lock out the service's user. A change does three things:

1. Under the lock, it writes `rules` and unlinks what the rule holds
   (`unlink-under`, including the subtitles beside videos). It forgets
   those files' seconds and owes Jellyfin a `Deleted`.
2. It releases the lock.
3. It starts the service and prints that invocation's journal.

The lock keeps a run in progress from writing back the seconds a change has
just forgotten.

## Testing

There is no test suite in the repo. Testing has meant loading the system
into an SBCL that has jzon and cl-ppcre, with guessit and ffprobe on the
PATH:

```sh
nix-build -o lisp -E '(import ./.).pkgs.sbcl.withPackages (ps: [ ps.com_dot_inuoe_dot_jzon ps.cl-ppcre ])'
nix-build -o guessit -E '(import ./.).pkgs.python3Packages.guessit'
```

Then build a fake seed tree, set the specials to it, and redefine
`remote-search` to answer from a list. Calling `(command '("resolve" …))`
and friends, and `(odos)` for runs, works without Jellyfin or root: with no
`*service*`, a change just says that a run places the files again. Garbage
`.mkv` files are fine, because ffprobe can't read either copy and the
linked one stays.

Build the real thing with
`nix-build -E '(import ./.).pkgs.callPackage ./lemma/odos/package.nix {}'`.
