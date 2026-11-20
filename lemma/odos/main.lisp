;;;; odos: the command line itself: flags and commands

(in-package #:odos)

(defun usage (&optional (code 64))
  (format (if (zerop code) *standard-output* *error-output*) "usage: odos [flags] [command]

  (none)                       a run: link what isn't linked
  list [--tmdb ID | --path P]  what's linked, by show, film or series
  unsure                       what the last run left alone, and why
  resolve PATH                 what a run would make of a file or folder, and why
  search TITLE [--film] [--year Y]
                               what tmdb finds, through jellyfin
  show PATH [tmdb] ID [season N [offset K]]
                               a folder or file is that show
  film PATH [tmdb] ID          ... that film
  episode FILE [tmdb] ID SEASON EP
                               a file is that episode
  series PATH NAME             a shelf's folder or file is that series
  ignore PATH                  never link it
  prefer PATH                  its copies win over others of the same episode or film
  relink PATH                  unlink it, and link it again
  rules [--nix]                the rules, or the command line's as nix
  forget RULE                  undo the command line's rules for a path

flags: --dry-run --video DIR --links DIR --shows DIR --films DIR --state DIR
       --spool DIR --jellyfin URL --key-file FILE --rules FILE
       --shelf TREE:LIBRARY... --service UNIT~%")
  (uiop:quit code))

(defparameter +flags+
  '(("--video" . *video*) ("--links" . *links*) ("--shows" . *shows*) ("--films" . *films*)
    ("--state" . *state*) ("--spool" . *spool*) ("--jellyfin" . *jellyfin*)
    ("--key-file" . *key-file*) ("--rules" . *rules-file*) ("--service" . *service*)))

(defun command (words)
  "Does what WORDS say. True unless a run owes jellyfin something."
  (let ((name (pop words)))
    (cond ((null name)
           ;; a run from the command line is the service's, as its user
           (if (and *service* (not *dry-run*)) (progn (rerun) t) (odos)))
          ((string= name "list") (cmd-list words) t)
          ((string= name "unsure") (when words (usage)) (cmd-unsure) t)
          ((string= name "resolve") (cmd-resolve words) t)
          ((string= name "search") (cmd-search words) t)
          ((string= name "show") (cmd-place :show words) t)
          ((string= name "film") (cmd-place :film words) t)
          ((string= name "episode") (cmd-place :episode words) t)
          ((string= name "series") (cmd-series words) t)
          ((string= name "ignore") (cmd-ignore words) t)
          ((string= name "prefer") (cmd-prefer words) t)
          ((string= name "relink") (cmd-relink words) t)
          ((string= name "rules") (cmd-rules words) t)
          ((string= name "forget") (cmd-forget words) t)
          ((member name '("help" "--help" "-h") :test #'string=) (usage 0))
          (t (usage)))))

(defun main ()
  (setf sb-alien::*default-c-string-external-format* :utf-8
        sb-impl::*default-external-format* :utf-8)
  (let ((args (rest sb-ext:*posix-argv*)) words)
    ;; flags anywhere; the rest is the command, in order
    (loop while args
          do (let* ((word (pop args)) (flag (assoc word +flags+ :test #'string=)))
               (cond ((string= word "--dry-run") (setf *dry-run* t))
                     ((string= word "--shelf")
                      (let* ((value (or (pop args) (usage)))
                             (colon (or (position #\: value) (usage))))
                        (setf *shelves* (append *shelves* (list (cons (subseq value 0 colon)
                                                                      (subseq value (1+ colon))))))))
                     (flag (setf (symbol-value (cdr flag)) (or (pop args) (usage))))
                     (t (push word words)))))
    (handler-case (uiop:quit (if (command (nreverse words)) 0 75))
      (error (e)
        (format *error-output* "odos: ~a~%" e)
        (uiop:quit 1)))))
