;;;; odos, the way from a torrent to a library: every video under the seed
;;;; tree that nothing links to yet is read by guessit and linked where
;;;; jellyfin expects it, shows as TV/Show (Year)/Season 02/Show S02E05.mkv
;;;; and films as Films/Title (Year)/Title (Year).mkv, subtitles beside
;;;; their video. links whose torrent went are removed. what guessit can't
;;;; place surely, or tmdb doesn't know, is listed instead, for linking by
;;;; hand or a rule, and jellyfin is told which folders changed. the shelf's
;;;; trees (manga, comics, books) are linked for kavita, by series.
;;;;
;;;; paths are native strings throughout, never pathnames: torrent names
;;;; are full of brackets and stars, which pathnames read as wildcards
;;;;
;;;; README.md says how its files fit together

(defpackage #:odos
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon) (#:ppcre #:cl-ppcre))
  (:export #:main))

(in-package #:odos)

(defvar *video* "/srv/seed/video" "What's linked to.")
(defvar *links* "/srv/kino" "Where links are looked for, which take a file; and the shelf's
libraries.")
(defvar *shows* "/srv/kino/TV")
(defvar *films* "/srv/kino/Films")
(defvar *state* "/var/lib/odos" "pending, what jellyfin hasn't heard yet; unsure, what odos left alone.")
(defvar *spool* nil "Emptied first: the done-hook's markers, which only say to run.")
(defvar *jellyfin* "http://127.0.0.1:8096")
(defvar *key-file* nil "Jellyfin's api key, or nothing to tell it.")
(defvar *dry-run* nil "Say what would be linked, and change nothing.")
(defvar *rules-file* nil "Where a torrent's folders and files are said to be, by a person.")
(defvar *shelves* '() "(tree . library) each: the shelf's trees under the seed tree, and kavita's
libraries their files are linked into.")

(defparameter +videos+
  '("mkv" "mp4" "m4v" "avi" "mov" "wmv" "webm" "ts" "m2ts" "mpg" "mpeg" "flv" "ogv"))
(defparameter +subtitles+ '("srt" "ass" "ssa" "vtt" "sub" "idx" "sup" "smi"))
(defparameter +shelf-files+ '("cbz" "cbr" "cb7" "cbt" "zip" "rar" "7z" "pdf" "epub"))

(defun say (control &rest args)
  (format t "~?~%" control args)
  (finish-output))

(defun number-in (v)
  "V, a number or a string of one (4500000, 23.976, 24000/1001), or nil."
  (typecase v
    (real v)
    (string (ignore-errors
             (let ((n (with-standard-io-syntax
                        (let ((*read-eval* nil)) (read-from-string v)))))
               (and (realp n) n))))))
