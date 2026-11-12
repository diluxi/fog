(asdf:defsystem "odos"
  :description "links finished torrents into jellyfin's libraries, by what guessit makes of their names"
  :license "MIT"
  :depends-on ("sb-posix" "com.inuoe.jzon")
  :components ((:file "odos")))
