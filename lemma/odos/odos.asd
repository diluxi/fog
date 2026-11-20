(asdf:defsystem "odos"
  :description "links finished torrents into jellyfin's libraries, by what guessit makes of their names"
  :license "MIT"
  :depends-on ("sb-posix" "com.inuoe.jzon" "cl-ppcre")
  ;; in the order README.md has them: each needs only those above it to
  ;; compile (its macros and specials)
  :serial t
  :components ((:file "package")
               (:file "files")
               (:file "guessit")
               (:file "tmdb")
               (:file "rules")
               (:file "place")
               (:file "copies")
               (:file "links")
               (:file "run")
               (:file "state")
               (:file "shelf")
               (:file "change")
               (:file "commands")
               (:file "resolve")
               (:file "main")))
