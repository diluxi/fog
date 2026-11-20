;;;; odos: rules: what a person says a path is

(in-package #:odos)

;;; rules: where a person says a torrent's folder or file is what, for what
;;; no name says well enough. one is
;;;
;;;   (path :film id)
;;;   (path :show id): the show's, in the seasons and episodes the names say
;;;   (path :show id :episodes ((from to season offset parts) ...)): episode
;;;     n of the files, from FROM to TO (or on), is episode n+OFFSET of
;;;     SEASON; or with PARTS, part n-FROM+1 of the one episode FROM+OFFSET,
;;;     which jellyfin plays as one (an hour-long premiere in two files)
;;;   (path :show id :episode (season number)): one file, that episode
;;;   (path :series "Name"): a shelf's files, that series
;;;   (path :ignore t): never linked (openings, endings, extras)
;;;   (path :prefer t): its copies win over any other copy of the same
;;;     episode or film, whatever ffprobe says
;;;
;;; :prefer goes with any of the others. a video's paths are relative to the
;;; seed tree's video, a shelf's to the seed tree, starting with its tree's
;;; name (manga/...). the longest path that holds a file is its rule: a
;;; folder above it, the file itself, or the video whose subtitles it is

(defvar *nix-rules* '() "The rules in *rules-file*, from nix.")
(defvar *cli-rules* '() "The rules odos's command line added, kept in *state*.")
(defvar *rules* '() "Both, the command line's first: of two for one path, theirs holds.")

(defun read-forms (file)
  (when (and file (eq (kind file) :file))
    (with-open-file (in file :external-format :utf-8)
      (let ((*read-eval* nil) (*package* (find-package :odos)))
        (loop for form = (read in nil in) until (eq form in) collect form)))))

(defun cli-rules-file () (join *state* "rules"))

(defun read-rules ()
  (setf *nix-rules* (read-forms *rules-file*)
        *cli-rules* (read-forms (cli-rules-file))
        *rules* (append *cli-rules* *nix-rules*)))

(defun stem (name)
  "NAME without its extension."
  (let ((dot (position #\. name :from-end t)))
    (if (and dot (> dot (1+ (or (position #\/ name :from-end t) -1))))
        (subseq name 0 dot)
        name)))

(defun holds (prefix rel)
  "Whether the rule's path PREFIX holds REL: is it, a folder above it, or a
video whose subtitle it is (Show 01.mkv holds Show 01.en.srt)."
  (flet ((starts (with)
           (and (> (length rel) (length with)) (string= with rel :end2 (length with)))))
    (or (string= rel prefix)
        (and (starts prefix) (char= (char rel (length prefix)) #\/))
        (and (member (extension prefix) +videos+ :test #'string=)
             (member (extension rel) +subtitles+ :test #'string=)
             (starts (stem prefix))
             (char= (char rel (length (stem prefix))) #\.)
             (not (find #\/ rel :start (length (stem prefix))))))))

(defun longest-rule (rel rules)
  "Of RULES, the one whose path is the longest that holds REL; the first of
the longest."
  (let (best)
    (dolist (r rules best)
      (when (and (holds (first r) rel)
                 (or (null best) (> (length (first r)) (length (first best)))))
        (setf best r)))))

(defun says (rule &rest keys)
  "Whether RULE says any of KEYS."
  (some (lambda (key) (getf (rest rule) key)) keys))

(defun shelf-rule-p (rule)
  "Whether RULE is for a shelf's files: its path starts with a tree's name."
  (some (lambda (shelf) (holds (basename (car shelf)) (first rule))) *shelves*))

(defun rule-for (path)
  "The rule that says what PATH, a video or a shelf's file, is; nil for none."
  (let ((shelf (shelf-of path)))
    (if shelf
        (longest-rule (relative (dirname (car shelf)) path)
                      (remove-if-not (lambda (r) (and (shelf-rule-p r) (says r :series :ignore)))
                                     *rules*))
        (longest-rule (relative *video* path)
                      (remove-if (lambda (r) (or (shelf-rule-p r) (not (says r :film :show :ignore))))
                                 *rules*)))))

(defun ignored (path)
  (says (rule-for path) :ignore))

(defun preference (path)
  "The rule that prefers the video PATH's copy, or nil."
  (longest-rule (relative *video* path)
                (remove-if-not (lambda (r) (and (not (shelf-rule-p r)) (says r :prefer))) *rules*)))
