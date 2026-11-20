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

;;; paths

(defun join (dir name)
  (if (string= dir "/") (concatenate 'string "/" name) (concatenate 'string dir "/" name)))

(defun dirname (path)
  (let ((slash (position #\/ path :from-end t)))
    (cond ((null slash) ".") ((zerop slash) "/") (t (subseq path 0 slash)))))

(defun basename (path)
  (subseq path (1+ (or (position #\/ path :from-end t) -1))))

(defun extension (path)
  (let* ((name (basename path)) (dot (position #\. name :from-end t)))
    (and dot (plusp dot) (string-downcase (subseq name (1+ dot))))))

(defun normalize (path)
  "PATH without . and .., lexically: what a link's target means."
  (let (parts)
    (dolist (p (uiop:split-string path :separator "/"))
      (cond ((member p '("" ".") :test #'string=))
            ((string= p "..") (pop parts))
            (t (push p parts))))
    (format nil "/~{~a~^/~}" (reverse parts))))

(defun under (root path)
  "Whether PATH is ROOT or inside it."
  (let ((n (length root)))
    (and (>= (length path) n) (string= root path :end2 n)
         (or (= (length path) n) (char= (char path n) #\/)))))

(defun relative (root path)
  (subseq path (min (length path) (1+ (length root)))))

;;; the file system, through sb-posix

(defun kind (path)
  "What PATH is, not following a link: :directory, :file, :link, :other, or
nil when there's nothing."
  (handler-case
      (let ((type (logand (sb-posix:stat-mode (sb-posix:lstat path)) sb-posix:s-ifmt)))
        (cond ((= type sb-posix:s-ifdir) :directory)
              ((= type sb-posix:s-ifreg) :file)
              ((= type sb-posix:s-iflnk) :link)
              (t :other)))
    (sb-posix:syscall-error () nil)))

(defun exists (path)
  "Whether PATH is there, following links."
  (handler-case (progn (sb-posix:stat path) t)
    (sb-posix:syscall-error () nil)))

(defun entries (dir)
  (let ((d (sb-posix:opendir dir)) names)
    (unwind-protect
         (loop for e = (sb-posix:readdir d)
               until (sb-alien:null-alien e)
               do (let ((name (sb-posix:dirent-name e)))
                    (unless (member name '("." "..") :test #'string=)
                      (push name names))))
      (sb-posix:closedir d))
    (sort names #'string<)))

(defun walk (root fn)
  "Calls FN with every path under ROOT and its kind, not following links. A
directory that can't be read is said and passed over."
  (dolist (name (handler-case (entries root)
                  ;; unreadable, or a name that isn't utf-8
                  (error (e)
                    (say "can't read ~a: ~a" root e)
                    nil)))
    (let* ((path (join root name)) (kind (kind path)))
      (funcall fn path kind)
      (when (eq kind :directory) (walk path fn)))))

(defun ensure-directories (path root)
  "Makes PATH and what's missing above it, up to ROOT, which must exist."
  (unless (or (string= path root) (kind path))
    (ensure-directories (dirname path) root)
    (sb-posix:mkdir path #o770)))

(defun prune (dir root)
  "Removes DIR if it's empty, and so on upwards, short of ROOT."
  (when (and (under root dir) (not (string= dir root))
             (eq (kind dir) :directory) (null (entries dir)))
    (sb-posix:rmdir dir)
    (prune (dirname dir) root)))

;;; what's linked already

(defun target (link)
  (let ((to (sb-posix:readlink link)))
    (normalize (if (char= (char to 0) #\/) to (join (dirname link) to)))))

(defun link-root (path)
  "The root PATH's link is under: a shelf's library, or *links*."
  (or (cdr (find-if (lambda (shelf) (under (cdr shelf) path)) *shelves*)) *links*))

(defun link-roots ()
  "Where links are: *links*, and the shelf's libraries not in it."
  (cons *links* (remove-if (lambda (library) (under *links* library))
                           (mapcar #'cdr *shelves*))))

(defun survey ()
  "The targets linked to from anywhere under *links* and the shelf's
libraries, as a set, after links into *video* or a shelf's tree whose file
is gone are removed. Returns the folders that lost one as the second
value."
  (let ((linked (make-hash-table :test 'equal)) gone)
    (dolist (root (link-roots))
      (when (eq (kind root) :directory)
        (walk root
              (lambda (path kind)
                (when (eq kind :link)
                  (let ((to (target path)))
                    (cond ((or (not (or (under *video* to) (shelf-of to))) (exists to))
                           (setf (gethash to linked) t))
                          (*dry-run* (say "would remove ~a, its file is gone" path))
                          (t (sb-posix:unlink path)
                             (say "removed ~a, its file is gone" path)
                             (push path gone)))))))))
    (dolist (link gone)
      (prune (dirname link) (link-root link)))
    (values linked (remove-duplicates (mapcar #'dirname gone) :test #'string=))))

(defun candidates (linked)
  "Videos and subtitles under *video* that nothing links to, but samples."
  (let (found)
    (walk *video*
          (lambda (path kind)
            (when (and (eq kind :file)
                       (member (extension path) (append +videos+ +subtitles+) :test #'string=)
                       (not (gethash path linked))
                       (not (find #\Newline path))
                       (not (search "/sample" (string-downcase path))))
              (push path found))))
    (nreverse found)))

;;; guessit

(defun readable (name)
  "NAME as guessit reads it best: a version after an episode (S01E01v2) makes
it read the whole name as a film's title, and a folder's place in a
collection (14. Owarimonogatari) as an episode's number, so both go."
  (ppcre:regex-replace-all
   "(^|/)\\d{1,3}\\.\\s+(?=[^/]*/)"
   (ppcre:regex-replace-all "(?i)\\b(S\\d{1,3}(?:E\\d{1,4})*)v\\d{1,2}\\b" name "\\1")
   "\\1"))

(defun guess (paths)
  "What guessit makes of each path, relative to *video* so a torrent's
folder names help, as hash tables in the same order; and as the second
value, what it makes of each file's name alone, for when the folders
mislead it (K-ON! - AV1/Season 1/K-ON! - 01.mkv is a show called AV1 to
it). Both from one guessit run."
  (when paths
    (let* ((names (append (mapcar (lambda (p) (readable (relative *video* p))) paths)
                          (mapcar (lambda (p) (readable (basename p))) paths)))
           (out (with-output-to-string (s)
                  (with-input-from-string (in (format nil "~{~a~%~}" names))
                    (uiop:run-program '("guessit" "--json" "--input-file" "/dev/stdin")
                                      :input in :output s :error-output *error-output*)))))
      (let ((lines (remove "" (uiop:split-string out :separator '(#\Newline)) :test #'string=)))
        (unless (= (length lines) (length names))
          (error "guessit answered ~d times for ~d names" (length lines) (length names)))
        (let ((guesses (mapcar #'jzon:parse lines)))
          (values (subseq guesses 0 (length paths))
                  (nthcdr (length paths) guesses)))))))

(defun field (guess name)
  "A field of GUESS, the first when guessit found several; nil for none."
  (let ((v (gethash name guess)))
    (cond ((eq v 'null) nil)
          ((and (vectorp v) (not (stringp v))) (and (plusp (length v)) (aref v 0)))
          (t v))))

(defun fields (guess name)
  (let ((v (gethash name guess)))
    (cond ((or (null v) (eq v 'null)) nil)
          ((and (vectorp v) (not (stringp v))) (coerce v 'list))
          (t (list v)))))

;;; jellyfin, asked and told through curl, whose config comes on stdin so
;;; the key is on no command line

(defvar *key* nil "Jellyfin's api key, or nil.")

(defun quoted (s)
  "S as a string in curl's config syntax."
  (with-output-to-string (o)
    (write-char #\" o)
    (loop for c across s
          do (when (member c '(#\" #\\)) (write-char #\\ o))
             (write-char c o))
    (write-char #\" o)))

(defun jellyfin (path body)
  "POSTs BODY, as json, to jellyfin's PATH. Its answer as a string, or nil if
it didn't take it."
  (with-input-from-string
      (in (format nil "url = ~a~%header = ~a~%header = \"Content-Type: application/json\"~%data = ~a~%fail~%silent~%show-error~%"
                  (quoted (format nil "~a~a" *jellyfin* path))
                  (quoted (format nil "Authorization: MediaBrowser Token=\"~a\"" *key*))
                  (quoted (jzon:stringify body))))
    (multiple-value-bind (out err code)
        (uiop:run-program '("curl" "--config" "-") :input in :output :string
                                                   :error-output *error-output* :ignore-error-status t)
      (declare (ignore err))
      (and (zerop code) out))))

(defun object (&rest pairs)
  "A json object of PAIRS, name then value."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on pairs by #'cddr do (setf (gethash k h) v))
    h))

;;; who a show or film is: what jellyfin's metadata (tmdb) calls it, asked
;;; once per title and kept, so a show under its english and its japanese
;;; name, or with and without a year, is one show, in a folder named by its
;;; tmdb id, which jellyfin reads as well

(defvar *ids* (make-hash-table :test 'equal)
  "kind|title|year to (id name year), or (:none . when) when tmdb didn't know
it, a universal time.")

(defparameter +retry+ (* 24 60 60)
  "How long tmdb not knowing a title is believed: it learns new shows, and a
lookup can fail.")

(defun ids-file () (join *state* "ids"))

(defun read-ids ()
  (when (eq (kind (ids-file)) :file)
    (with-open-file (in (ids-file) :external-format :utf-8)
      (loop for line = (read-line in nil)
            while line
            do (destructuring-bind (key id &optional name year)
                   (uiop:split-string line :separator '(#\Tab))
                 ;; a miss without its time is from before they had one
                 (setf (gethash key *ids*)
                       (if (string= id "-")
                           (cons :none (or (number-in name) 0))
                           (list id name (number-in year)))))))))

(defun write-ids ()
  (write-lines (ids-file)
               (loop for key being the hash-keys of *ids* using (hash-value v)
                     collect (if (eq (car v) :none)
                                 (format nil "~a~c-~c~d" key #\Tab #\Tab (cdr v))
                                 (destructuring-bind (id name year) v
                                   (format nil "~a~c~a~c~a~c~@[~d~]" key #\Tab id #\Tab name #\Tab year))))))

(defun remote-search (kind title year &optional tmdb)
  "What jellyfin's metadata finds for TITLE (in YEAR, if one), or for the tmdb
id TMDB: (id name year) for each tmdb result, in jellyfin's order;
:unreachable if jellyfin can't be asked."
  (let ((out (and *key*
                  (jellyfin (format nil "/Items/RemoteSearch/~a" (if (eq kind :film) "Movie" "Series"))
                            (object "SearchInfo"
                                    (cond (tmdb (object "ProviderIds" (object "Tmdb" (princ-to-string tmdb))))
                                          (year (object "Name" title "Year" year))
                                          (t (object "Name" title))))))))
    (if (null out)
        :unreachable
        (loop for r in (coerce (jzon:parse out) 'list)
              for ids = (gethash "ProviderIds" r)
              when (and (hash-table-p ids) (stringp (gethash "Tmdb" ids)))
                collect (list (gethash "Tmdb" ids)
                              (gethash "Name" r)
                              (let ((y (gethash "ProductionYear" r))) (and (integerp y) y)))))))

(defun look-up (kind title year &optional tmdb)
  "Of what jellyfin's metadata finds, (id name year): the tmdb id TMDB's, or
the first of YEAR, or the first; :none for nothing; :unreachable if jellyfin
can't be asked."
  (let ((results (remote-search kind title year tmdb)))
    (if (eq results :unreachable)
        :unreachable
        (or (cond (tmdb (find (princ-to-string tmdb) results :key #'first :test #'equal))
                  ((and year (find year results :key #'third)))
                  (t (first results)))
            :none))))

(defun identify (kind title year &optional tmdb)
  "(id name year) for TITLE, or for the tmdb id TMDB; :none, or :unreachable."
  (let ((key (if tmdb
                 (format nil "~(~a~)|tmdb:~a" kind tmdb)
                 (format nil "~(~a~)|~a|~@[~d~]" kind (fold title) year))))
    (let ((known (gethash key *ids*)))
      (cond ((and known (not (eq (car known) :none))) known)
            ((and known (< (- (get-universal-time) (cdr known)) +retry+)) :none)
            (t (let ((found (if *key* (look-up kind title year tmdb) :none)))
                 ;; without a key, guessit's title, but nothing to remember
                 (unless (or (eq found :unreachable) (null *key*))
                   (setf (gethash key *ids*)
                         (if (eq found :none) (cons :none (get-universal-time)) found)))
                 found))))))

;;; where things go

(defun clean (title)
  "TITLE as a file name: no slashes, no dots or spaces at its ends."
  (let ((s (substitute #\Space #\/ title)))
    (string-trim " ." (with-output-to-string (o)
                        (loop for c across s and prev = nil then c
                              unless (and (char= c #\Space) (eql prev #\Space))
                                do (write-char c o))))))

(defun fold (name)
  "A folder name as compared: in lower case, without its tmdb id or (year)."
  (string-trim " " (ppcre:regex-replace-all "\\s*(\\[tmdbid-\\d+\\]|\\(\\d{4}\\))\\s*$"
                                            (ppcre:regex-replace-all "\\s*\\[tmdbid-\\d+\\]" (string-downcase name) "")
                                            "")))

(defun tmdb-of (name)
  (nth-value 1 (ppcre:scan-to-strings "\\[tmdbid-(\\d+)\\]" name)))

(defun folders (root)
  "ROOT's folders by their tmdb ids and by their folded names."
  (let ((index (make-hash-table :test 'equal)))
    (when (eq (kind root) :directory)
      (dolist (name (entries root))
        (when (eq (kind (join root name)) :directory)
          (let ((id (tmdb-of name)))
            (when id (setf (gethash (format nil "id:~a" (aref id 0)) index) name)))
          (setf (gethash (fold name) index) name))))
    index))

(defun folder (index kind candidates)
  "The folder a show or film has, or a new one, named by tmdb: for the first
of CANDIDATES, (title year) each, that tmdb knows. Its title is the second
value. nil when tmdb knows none of them, :defer when jellyfin can't be
asked. Without an api key nothing can be known, so it's named by the
first's title and year, as guessit read them."
  (if (null *key*)
      (destructuring-bind (title year) (first candidates)
        (values (or (gethash (fold title) index)
                    (setf (gethash (fold title) index)
                          (if year (format nil "~a (~d)" title year) title)))
                title))
      (dolist (candidate candidates nil)
        (let ((id (apply #'identify kind candidate)))
          (cond ((eq id :unreachable) (return :defer))
                ((consp id) (return (known-folder index id))))))))

(defun known-folder (index id)
  "The folder for ID, (tmdb name year), and its title."
  (destructuring-bind (tmdb name tmdb-year) id
    (let ((name (clean name)))
      (values (or (gethash (format nil "id:~a" tmdb) index)
                  (let ((new (format nil "~a~@[ (~d)~] [tmdbid-~a]" name tmdb-year tmdb)))
                    (setf (gethash (format nil "id:~a" tmdb) index) new
                          (gethash (fold new) index) new)))
              name))))

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

(defun numbers (path guess)
  "The episode numbers PATH holds: guessit's, or the one before \" - \" in its
name (Owarimonogatari 2nd Season 01 - Mayoi Hell)."
  (or (remove-if-not #'integerp (fields guess "episode"))
      (let ((m (nth-value 1 (ppcre:scan-to-strings "(\\d{1,3}) - " (basename path)))))
        (and m (list (parse-integer (aref m 0)))))))

(defun episode-place (folder name season episodes &optional part)
  (values (format nil "~a/~a/Season ~2,'0d/~a S~2,'0dE~{~2,'0d~^-E~}~@[ - part~d~]"
                  *shows* folder season name season episodes part)
          (list* :episode (fold folder) season episodes (and part (list part)))))

(defun place-by-rule (rule path guess shows films)
  (destructuring-bind (prefix &key film show episodes episode ignore &allow-other-keys) rule
    (declare (ignore prefix))
    (flet ((by-id (index kind id)
             (let ((found (identify kind nil nil id)))
               (cond ((eq found :unreachable) (return-from place-by-rule (values nil :defer)))
                     ((consp found) (known-folder index found))
                     (t (return-from place-by-rule
                          (values nil (format nil "tmdb doesn't know the rule's ~(~a~) ~a" kind id))))))))
      (cond (ignore (values nil :ignored))
            (film
             (let ((folder (by-id films :film film)))
               (values (format nil "~a/~a/~a" *films* folder folder) (list :film (fold folder)))))
            ((and show episode)
             (multiple-value-bind (folder name) (by-id shows :show show)
               (episode-place folder name (first episode) (list (second episode)))))
            ((and show (null episodes))
             (let ((season (let ((v (field guess "season"))) (and (integerp v) v)))
                   (ns (numbers path guess)))
               (cond ((null ns) (values nil "no episode number for the rule"))
                     ((null season) (values nil "no season in its name, nor in the rule"))
                     (t (multiple-value-bind (folder name) (by-id shows :show show)
                          (episode-place folder name season ns))))))
            (show
             (let* ((ns (numbers path guess))
                    (segment (and ns (find-if (lambda (seg)
                                                (destructuring-bind (from to &rest _) seg
                                                  (declare (ignore _))
                                                  (and (>= (first ns) from) (or (null to) (<= (first ns) to)))))
                                              episodes))))
               (cond ((null ns) (values nil "no episode number for the rule"))
                     ((null segment) (values nil (format nil "the rule has no season for episode ~d" (first ns))))
                     (t (destructuring-bind (from to season offset &optional parts) segment
                          (declare (ignore to))
                          (multiple-value-bind (folder name) (by-id shows :show show)
                            (let ((eps (if parts
                                           (list (+ from offset))
                                           (mapcar (lambda (n) (+ n offset)) ns)))
                                  (part (and parts (1+ (- (first ns) from)))))
                              (episode-place folder name season eps part))))))))
            (t (values nil "a rule that says neither film nor show"))))))

(defun title-and-year (guess)
  "(title year) as GUESS has them, or nil without a title."
  (let ((title (let ((v (field guess "title"))) (and (stringp v) (clean v))))
        (year (let ((v (field guess "year"))) (and (integerp v) v))))
    (and title (string/= title "") (list title year))))

(defun titles (guess alone)
  "Who a file may be, (title year) each, first as GUESS has it, then as
ALONE has it."
  (remove-duplicates (remove nil (list (title-and-year guess) (title-and-year alone)))
                     :test #'equal :from-end t
                     :key (lambda (c) (list (fold (first c)) (second c)))))

(defun reads-as (guess)
  "What GUESS reads a file as: :show or :film, or nil. An \"episode\" with
neither season nor number is a film whose name has a word guessit takes for
an episode's (Blade.Runner.Final.Cut)."
  (let ((type (field guess "type")))
    (cond ((and (equal type "episode")
                (or (integerp (field guess "season"))
                    (some #'integerp (fields guess "episode"))))
           :show)
          ((member type '("movie" "episode") :test #'equal) :film))))

(defun place (path guess alone shows films)
  "Where PATH, which GUESS is of, goes, without its extension, and its key for
subtitles; or nil and why not, or nil and :defer when jellyfin can't say who
it is yet. A rule for it goes first. Who it is is the title GUESS has, or
else the one ALONE has, guessit's reading of the file's name alone; what
season and episode, GUESS's. SHOWS and FILMS index their roots' folders."
  (let ((rule (rule-for path)))
    (when rule
      (return-from place (place-by-rule rule path guess shows films))))
  (let ((candidates (titles guess alone))
        (season (let ((v (field guess "season"))) (and (integerp v) v)))
        (episodes (remove-if-not #'integerp (fields guess "episode"))))
    (flet ((unknown ()
             (values nil (format nil "tmdb knows no ~{~a~^ or ~}"
                                 (mapcar (lambda (c) (format nil "~a~@[ (~d)~]" (first c) (second c)))
                                         candidates)))))
    (cond ((null candidates) (values nil "no title"))
          ((eq (reads-as guess) :show)
           (cond ((null episodes) (values nil "an episode without its number"))
                 ((null season) (values nil "an episode without a season (absolute numbering?)"))
                 (t (multiple-value-bind (show name) (folder shows :show candidates)
                      (cond ((eq show :defer) (values nil :defer))
                            ((null show) (unknown))
                            (t (episode-place show name season episodes)))))))
          ((eq (reads-as guess) :film)
           (let ((film (folder films :film candidates)))
             (cond ((eq film :defer) (values nil :defer))
                   ((null film) (unknown))
                   (t (values (format nil "~a/~a/~a" *films* film film)
                              (list :film (fold film)))))))
          (t (values nil (format nil "neither episode nor film: ~a" (field guess "type"))))))))

;;; which of two copies is better
;;;
;;; by what the files are, as ffprobe reads them, not by their names: guessit
;;; doesn't know av1, and names are what a release says of itself. compared
;;; key by key, the first difference deciding:
;;;
;;;   1. resolution, as a tier: 2160p, 1440p, 1080p, ... a cropped 1920x800
;;;      is 1080p
;;;   2. codec, by how much picture it keeps per bit: av1, hevc, vp9, h264,
;;;      vc1, mpeg-2 and mpeg-4, anything else
;;;   3. bit depth: 10 bits over 8, fewer bands in gradients
;;;   4. hdr over sdr
;;;   5. with all that equal, so the same codec at the same size: the video's
;;;      bit rate, measured over the same stretch of both, since they're the
;;;      same episode or film. it wins only by more than a sixth, so encodes
;;;      about as good don't swap, and the one that's linked stays
;;;
;;; a copy ffprobe can't read loses to one it can.

(defparameter +tiers+ '(4320 2160 1440 1080 720 576 480 360 240))
(defparameter +codecs+ '("av1" "hevc" "vp9" "h264" "vc1" ("mpeg2video" "mpeg4")))
(defparameter +margin+ 7/6 "How much more bit rate a copy needs to beat the linked one.")
(defparameter +stretch+ '(120 30) "Where bit rates are measured: from 2:00, for 30 s.")

(defun number-in (v)
  "V, a number or a string of one (4500000, 23.976, 24000/1001), or nil."
  (typecase v
    (real v)
    (string (ignore-errors
             (let ((n (with-standard-io-syntax
                        (let ((*read-eval* nil)) (read-from-string v)))))
               (and (realp n) n))))))

(defun ffprobe (&rest args)
  (multiple-value-bind (out err code)
      (uiop:run-program (cons "ffprobe" (list* "-v" "error" args))
                        :output :string :error-output nil :ignore-error-status t)
    (declare (ignore err))
    (and (zerop code) out)))

(defun probe (path)
  "PATH's video as ffprobe reads it: (tier codec depth hdr width height fps
duration), or nil."
  (let* ((out (ffprobe "-print_format" "json" "-show_format" "-show_streams"
                       (concatenate 'string "file:" path)))
         (json (and out (ignore-errors (jzon:parse out))))
         (video (and json
                     (find-if (lambda (s)
                                (and (equal (gethash "codec_type" s) "video")
                                     ;; not cover art
                                     (not (eql 1 (gethash "attached_pic" (gethash "disposition" s))))))
                              (gethash "streams" json)))))
    (when video
      (let* ((w (or (number-in (gethash "width" video)) 0))
             (h (or (number-in (gethash "height" video)) 0))
             (size (max h (* w 9/16)))
             (pix (gethash "pix_fmt" video))
             (transfer (gethash "color_transfer" video)))
        (list :tier (or (find-if (lambda (tier) (>= size (* tier 19/20))) +tiers+) 0)
              :codec (let ((c (gethash "codec_name" video)))
                       (- (length +codecs+)
                          (or (position-if (lambda (k) (if (listp k) (member c k :test #'equal) (equal c k)))
                                           +codecs+)
                              (length +codecs+))))
              :depth (if (and (stringp pix) (search "10" pix)) 10 8)
              :hdr (if (member transfer '("smpte2084" "arib-std-b67") :test #'equal) 1 0)
              :name (format nil "~dp ~a~:[~; 10-bit~]~:[~; hdr~]"
                            (or (find-if (lambda (tier) (>= size (* tier 19/20))) +tiers+) h)
                            (gethash "codec_name" video)
                            (and (stringp pix) (search "10" pix))
                            (member transfer '("smpte2084" "arib-std-b67") :test #'equal))
              :duration (number-in (gethash "duration" (gethash "format" json))))))))

(defun bit-rate (path duration)
  "Bits a second of PATH's video over +stretch+, or from the start if it's
shorter; nil if ffprobe can't say."
  (destructuring-bind (from span) +stretch+
    (let* ((from (if (and duration (> duration (+ from span))) from 0))
           (out (ffprobe "-select_streams" "v:0" "-read_intervals" (format nil "~d%+~d" from span)
                         "-show_entries" "packet=size,pts_time" "-of" "csv=p=0"
                         (concatenate 'string "file:" path)))
           (packets (and out (loop for line in (uiop:split-string out :separator '(#\Newline))
                                   for (time size) = (uiop:split-string line :separator ",")
                                   for tn = (number-in time) and sn = (number-in size)
                                   when (and tn sn) collect (cons tn sn)))))
      (when (cdr packets)
        (let ((first (reduce #'min packets :key #'car))
              (last (reduce #'max packets :key #'car)))
          (when (> last first)
            (/ (* 8 (reduce #'+ packets :key #'cdr)) (- last first))))))))

(defun better (new old)
  "Whether the copy at NEW beats the one at OLD, and why, as a string."
  (let ((a (probe new)) (b (probe old)))
    (cond ((null a) (values nil "ffprobe can't read it"))
          ((null b) (values t "ffprobe can't read the linked one"))
          (t (loop for key in '(:tier :codec :depth :hdr)
                   for x = (getf a key) and y = (getf b key)
                   when (/= x y)
                     do (return-from better
                          (values (> x y) (format nil "~a ~:[loses to~;over~] ~a"
                                                  (getf a :name) (> x y) (getf b :name)))))
             (let ((x (bit-rate new (getf a :duration)))
                   (y (bit-rate old (getf b :duration))))
               (cond ((or (null x) (null y)) (values nil "bit rates unknown, the linked one stays"))
                     (t (let ((win (> x (* y +margin+))))
                          (values win (format nil "~a at ~,1f Mbit/s ~:[stays behind~;over~] ~,1f Mbit/s"
                                              (getf a :name) (/ x 1000000) win (/ y 1000000)))))))))))

(defun wins (new old)
  "Whether the copy at NEW beats the one at OLD, and why: a rule's preference
first, then which is better."
  (let ((a (preference new)) (b (and (under *video* old) (preference old))))
    (cond ((and a (not b)) (values t (format nil "a rule prefers it (~s)" (first a))))
          ((and b (not a)) (values nil (format nil "a rule prefers the linked one (~s)" (first b))))
          (t (better new old)))))

;;; the run

(defstruct run
  (linked 0) (upgraded 0) (deferred 0) (unsure '()) (changed '()) (seconds '())
  ;; in a dry run, where links would be, as nothing is made
  (planned (make-hash-table :test 'equal)))

(defun note-unsure (run path why)
  (push (cons path why) (run-unsure run)))

(defun linked-to (run dest)
  "What DEST links to, or would after this dry run; nil if nothing's there,
:taken if something else is."
  (or (gethash dest (run-planned run))
      (case (kind dest)
        ((nil) nil)
        (:link (target dest))
        (t :taken))))

(defun make-link (run target dest &optional replace)
  "DEST links to TARGET; a REPLACEd link is swapped in one rename."
  (cond (*dry-run* (setf (gethash dest (run-planned run)) target))
        (t (ensure-directories (dirname dest) (link-root dest))
           (if replace
               (let ((new (concatenate 'string dest ".odos")))
                 (when (kind new) (sb-posix:unlink new))
                 (sb-posix:symlink target new)
                 (sb-posix:rename new dest))
               (sb-posix:symlink target dest))
           (push (dirname dest) (run-changed run)))))

(defun drop-sidecars (dest)
  "Removes the subtitle links beside DEST's video, which belong to the copy
it linked before. Returns what they linked to."
  (let* ((stem (let ((name (basename dest))) (subseq name 0 (position #\. name :from-end t))))
         (dir (dirname dest))
         dropped)
    ;; in a dry run, the folder may only be planned
    (dolist (name (and (eq (kind dir) :directory) (entries dir)) dropped)
      (let ((path (join dir name)))
        (when (and (eq (kind path) :link)
                   (> (length name) (length stem))
                   (string= stem name :end2 (length stem))
                   (char= (char name (length stem)) #\.)
                   (member (extension name) +subtitles+ :test #'string=))
          (push (target path) dropped)
          (if *dry-run*
              (say "would remove ~a" path)
              (sb-posix:unlink path)))))))

(defun put (run target dest)
  "Links DEST to TARGET, a subtitle: a place taken is left as it is."
  (let ((there (linked-to run dest)))
    (cond ((null there)
           (make-link run target dest)
           (say "~:[~;would link ~]~a -> ~a" *dry-run* dest target)
           (incf (run-linked run))
           t)
          ((equal there target) t)
          (t (note-unsure run target (format nil "~a is taken" dest)) nil))))

(defun put-video (run target dest)
  "Links DEST to the video TARGET. Where another copy is linked, the better
of the two is. Returns :linked, and the copy it replaced if it did, or
:second when the other copy stays, or nil when it can't be placed."
  (let ((there (linked-to run dest)))
    (cond ((null there)
           (make-link run target dest)
           (say "~:[~;would link ~]~a -> ~a" *dry-run* dest target)
           (incf (run-linked run))
           :linked)
          ((equal there target) :linked)
          ((eq there :taken) (note-unsure run target (format nil "~a is taken" dest)) nil)
          ;; two files of one torrent are no copies of each other: one of
          ;; them was read wrong
          ((and (under *video* there) (string/= (torrent target) "")
                (equal (torrent there) (torrent target)))
           (note-unsure run target (format nil "~a has another file of this torrent (read wrong?)" dest))
           nil)
          (t (multiple-value-bind (win why) (wins target there)
               (cond (win
                      ;; the copy that was linked is a second now, with its
                      ;; subtitles
                      (dolist (sub (drop-sidecars dest))
                        (push (list sub dest there) (run-seconds run)))
                      (push (list there dest there) (run-seconds run))
                      (make-link run target dest t)
                      (say "~:[upgraded~;would upgrade~] ~a: ~a~%  now ~a~%  was ~a"
                           *dry-run* dest why target there)
                      (incf (run-upgraded run))
                      (values :linked there))
                     (t (say "~a stays: ~a~%  kept ~a~%  over ~a" dest why there target)
                        (push (list target dest target) (run-seconds run))
                        :second)))))))

(defmacro unless-failing ((run path) &body body)
  "BODY, for one file: if it fails, the file is left alone, with the error
for its reason, and the run goes on."
  `(handler-case (progn ,@body)
     (error (e) (note-unsure ,run ,path (format nil "odos failed: ~a" e)))))

(defun torrent (path)
  "The torrent PATH came with, as far as the seed tree says: the folder at its
top, or nothing for a file there on its own."
  (let* ((rel (relative *video* path)) (slash (position #\/ rel)))
    (if slash (subseq rel 0 slash) "")))

(defun link-all (run paths)
  (multiple-value-bind (guesses alones) (guess paths)
  (let* ((shows (folders *shows*))
         (films (folders *films*))
         ;; what became of each video, by what it is and the torrent it came
         ;; with, for its subtitles: where it's linked, or (:second place video)
         (stems (make-hash-table :test 'equal)))
    ;; videos first, so subtitles find where theirs went
    (loop for path in paths and g in guesses and a in alones
          when (member (extension path) +videos+ :test #'string=)
            do (unless-failing (run path)
                (unless (find "Sample" (fields g "other") :test #'equal)
                 (multiple-value-bind (stem key) (place path g a shows films)
                   (cond
                     ((eq key :defer) (incf (run-deferred run)))
                     ((eq key :ignored))
                     ((null stem) (note-unsure run path key))
                     (t
                       (let ((dest (format nil "~a.~a" stem (extension path))))
                         (multiple-value-bind (result replaced) (put-video run path dest)
                           (case result
                             (:linked
                              (setf (gethash (cons key (torrent path)) stems) stem)
                              ;; a copy linked earlier in this run lost its place
                              (when replaced
                                (setf (gethash (cons key (torrent replaced)) stems)
                                      (list :second dest replaced))))
                             ;; its subtitles stay out with it
                             (:second
                              (setf (gethash (cons key (torrent path)) stems)
                                    (list :second dest path))))))))))))
    (loop for path in paths and g in guesses and a in alones
          when (member (extension path) +subtitles+ :test #'string=)
            do (unless-failing (run path)
                (multiple-value-bind (stem key) (place path g a shows films)
                 (let ((stem (and stem (gethash (cons key (torrent path)) stems)))
                       (language (field g "subtitle_language")))
                   (cond ((stringp stem)
                          (put run path (format nil "~a~@[.~a~].~a" stem
                                                (and (stringp language) language)
                                                (extension path))))
                         ((consp stem)
                          (destructuring-bind (dest video) (rest stem)
                            (push (list path dest video) (run-seconds run))))))))))))

;;; the shelf: manga, comics and books, for kavita. kavita reads series,
;;; volumes and chapters from file names itself, and wants each series in a
;;; folder of its own; so each file keeps its name, in a folder named for
;;; its series, and kavita reads the rest

(defun shelf-of (path)
  "The shelf, (tree . library), whose tree PATH is under."
  (find-if (lambda (shelf) (under (car shelf) path)) *shelves*))

(defun shelf-candidates (linked)
  "Files of the shelf's kinds under its trees that nothing links to."
  (let (found)
    (dolist (shelf *shelves* (nreverse found))
      (when (eq (kind (car shelf)) :directory)
        (walk (car shelf)
              (lambda (path kind)
                (when (and (eq kind :file)
                           (member (extension path) +shelf-files+ :test #'string=)
                           (not (gethash path linked))
                           (not (find #\Newline path)))
                  (push path found))))))))

(defun series-name (name)
  "NAME, a folder's or a file's without its extension, as a series: without
its tags ([group], (Digital), (2019)), and without the volumes or chapters
it holds (v01-10, c001, Vol. 3, 001-054) and what follows them; a number
at its end goes only as a range or padded (Saga 001), so Fahrenheit 451
stays. Dots and underscores are spaces when there are no spaces. Empty
when nothing's left (Volume 01)."
  (let* ((s (ppcre:regex-replace-all "\\[[^]]*\\]|\\([^)]*\\)|\\{[^}]*\\}" name " "))
         (s (substitute #\Space #\_ s))
         (s (if (find #\Space (string-trim " " s)) s (substitute #\Space #\. s)))
         (s (ppcre:regex-replace
             "(?i)(^|\\s)(v|vol\\.?|volume|c|ch\\.?|chapter|#)\\s*\\d.*$" s ""))
         (s (ppcre:regex-replace "(^|\\s)(\\d{1,4}\\s*-\\s*\\d{1,4}|0\\d{1,3})\\s*$" s "")))
    (clean (string-trim " -" s))))

(defun shelf-series (path shelf)
  "The series PATH is of: the rule's, if a rule says, else what's left of the
names of the folders above it, nearest first, up to its torrent's, as a
series; else its own name's. nil when none says."
  (let ((root (car shelf))
        (rule (rule-for path)))
    (if (says rule :series)
        (getf (rest rule) :series)
        (let ((name (loop for dir = (dirname path) then (dirname dir)
                          while (and (under root dir) (string/= dir root))
                          for series = (series-name (basename dir))
                          when (string/= series "") return series)))
          (or name
              (let* ((file (basename path))
                     (series (series-name (subseq file 0 (or (position #\. file :from-end t)
                                                             (length file))))))
                (and (string/= series "") series)))))))

(defun link-shelf (run paths)
  "Links each of PATHS into its shelf's library, as Series/file."
  (let ((indexes (make-hash-table :test 'equal)))
    (dolist (path paths)
      (unless-failing (run path)
        (let* ((shelf (shelf-of path))
               (library (cdr shelf))
               (index (or (gethash library indexes)
                          (setf (gethash library indexes) (folders library))))
               (series (shelf-series path shelf)))
          (if (null series)
              (note-unsure run path "no series in its name or its folders'")
              (let ((folder (or (gethash (fold series) index)
                                (setf (gethash (fold series) index) series))))
                (put run path (join (join library folder) (basename path))))))))))

;;; telling jellyfin

(defun tell (updates)
  "Tells jellyfin about UPDATES, (type . path) each. True if it took them."
  (jellyfin "/Library/Media/Updated"
            (object "Updates" (coerce (loop for (type . path) in updates
                                            collect (object "Path" path "UpdateType" type))
                                      'vector))))

(defun pending-file () (join *state* "pending"))

(defun read-pairs (file)
  "FILE's lines as (a . b), from a<tab>b; nothing if there's no FILE."
  (when (eq (kind file) :file)
    (with-open-file (in file :external-format :utf-8)
      (loop for line = (read-line in nil)
            while line
            for tab = (position #\Tab line)
            when tab collect (cons (subseq line 0 tab) (subseq line (1+ tab)))))))

(defun read-pending () (read-pairs (pending-file)))

(defun write-lines (file lines)
  (with-open-file (out (concatenate 'string file ".new") :direction :output
                       :if-exists :supersede :external-format :utf-8)
    (dolist (l lines) (format out "~a~%" l)))
  ;; root, odos's command line, keeps what it writes odos's
  (when (zerop (sb-posix:getuid))
    (let ((dir (sb-posix:stat (dirname file))))
      (sb-posix:chown (concatenate 'string file ".new")
                      (sb-posix:stat-uid dir) (sb-posix:stat-gid dir))))
  ;; not rename-file, which would give the new name the old one's type
  (sb-posix:rename (concatenate 'string file ".new") file))

(defun write-pairs (file pairs)
  (write-lines file (loop for (a . b) in pairs collect (format nil "~a~c~a" a #\Tab b))))

(defun write-pending (updates) (write-pairs (pending-file) updates))

;;; copies that lost: each is passed over, unread, while another copy is
;;; linked at its place. if that goes, or this copy's own video comes back,
;;; it's a candidate again. a video is its own video; a subtitle's is the
;;; video it came with

(defun seconds-file () (join *state* "seconds"))

(defun read-seconds ()
  "(copy place video) each."
  (loop for (copy . rest) in (read-pairs (seconds-file))
        for tab = (position #\Tab rest)
        when tab collect (list copy (subseq rest 0 tab) (subseq rest (1+ tab)))))

(defun write-seconds (seconds)
  (write-lines (seconds-file)
               (loop for (copy place video) in seconds
                     collect (format nil "~a~c~a~c~a" copy #\Tab place #\Tab video))))

(defun settled (seconds)
  "The SECONDS that still hold."
  (remove-if-not (lambda (s)
                   (destructuring-bind (copy place video) s
                     (and (exists copy)
                          (eq (kind place) :link)
                          (exists place)
                          (not (equal (target place) video)))))
                 seconds))

(defun jellyfins (dir)
  "Whether jellyfin should hear of DIR; kavita scans its libraries itself."
  (or (under *shows* dir) (under *films* dir)))

(defun report (run gone)
  "What changed is added to what jellyfin hasn't heard yet, which is told.
False if jellyfin couldn't be reached, and it's kept for next time."
  (let* ((jellyfins #'jellyfins)
         (updates (remove-duplicates
                   (append (read-pending)
                           (mapcar (lambda (d) (cons "Created" d))
                                   (remove-if-not jellyfins (run-changed run)))
                           (mapcar (lambda (d) (cons "Deleted" d))
                                   (remove-if-not jellyfins gone)))
                   :test #'equal)))
    (cond ((or (null updates) *dry-run*) t)
          ((null *key*) (say "no api key, so jellyfin finds these on its next scan") t)
          ((tell updates)
           (say "jellyfin scans ~d folder~:p" (length updates))
           (write-pending '())
           t)
          (t (say "jellyfin didn't answer; ~d folder~:p wait for the next run" (length updates))
             (write-pending updates)
             nil))))

(defun empty-spool ()
  (when (and *spool* (eq (kind *spool*) :directory))
    (dolist (name (entries *spool*))
      (handler-case (sb-posix:unlink (join *spool* name))
        (sb-posix:syscall-error () nil)))))

(defun lock ()
  "Waits until no other odos changes *state* or the links, and keeps others
waiting until the descriptor it returns is closed, or odos exits."
  (let ((fd (sb-posix:open *state* sb-posix:o-rdonly)))
    (unless (zerop (sb-alien:alien-funcall
                    (sb-alien:extern-alien "flock" (function sb-alien:int sb-alien:int sb-alien:int))
                    fd 2))                ; LOCK_EX
      (sb-posix:close fd)
      (error "can't lock ~a" *state*))
    fd))

(defmacro with-lock (&body body)
  (let ((fd (gensym)))
    `(let ((,fd (lock)))
       (unwind-protect (progn ,@body) (sb-posix:close ,fd)))))

(defun setup ()
  "Reads what a run or a command needs: jellyfin's key, tmdb's ids, the rules."
  (setf *key* (and *key-file* (eq (kind *key-file*) :file)
                   (string-trim '(#\Space #\Newline #\Tab) (uiop:read-file-string *key-file*))))
  (read-ids)
  (read-rules))

(defun odos ()
  "One run. True unless jellyfin is owed a report it couldn't take, or
couldn't say who something is."
  (if *dry-run* (pass) (with-lock (pass))))

(defun pass ()
  (empty-spool)
  (setup)
  (unless *key* (say "no api key: shows and films are named by guessit alone"))
  (unless *dry-run*
    (dolist (root (list *shows* *films*))
      (ensure-directories root *links*))
    (dolist (library (mapcar #'cdr *shelves*))
      (ensure-directories library (dirname library))))
  (multiple-value-bind (linked gone) (survey)
    (let* ((run (make-run))
           (seconds (settled (read-seconds)))
           (paths (remove-if (lambda (p) (or (assoc p seconds :test #'equal) (ignored p)))
                             (candidates linked))))
      (when paths (link-all run paths))
      (let ((books (remove-if #'ignored (shelf-candidates linked))))
        (when books (link-shelf run books)))
      (unless *dry-run*
        (write-ids)
        ;; the latest word on each copy
        (write-seconds (settled (remove-duplicates (append seconds (reverse (run-seconds run)))
                                                   :key #'first :test #'equal :from-end nil)))
        (write-lines (join *state* "unsure")
                     (loop for (path . why) in (reverse (run-unsure run))
                           collect (format nil "~a~c~a" why #\Tab path))))
      (loop for (path . why) in (reverse (run-unsure run))
            do (say "left alone, ~a: ~a" why path))
      (say "~d linked, ~d upgraded, ~d kept out for a better copy, ~d left for linking by hand~@[ (~a)~]"
           (run-linked run) (run-upgraded run)
           (length (remove-duplicates (run-seconds run) :key #'first :test #'equal))
           (length (run-unsure run))
           (and (run-unsure run) (not *dry-run*) (join *state* "unsure")))
      (when (plusp (run-deferred run))
        (say "~d file~:p wait for jellyfin to say what they are" (run-deferred run)))
      (and (report run gone) (zerop (run-deferred run))))))

;;; the command line: what's linked and what's left alone, why a file goes
;;; where it does, and rules made on lemma0 rather than in nix, kept in
;;; *state*/rules (odos rules --nix prints them for odos-rules.nix). what
;;; changes where files go unlinks those they hold and starts odos's
;;; service, which links them again, as odos's own user

(defvar *service* nil "The unit that runs odos, started after a change.")

(defun all-links ()
  "Every link under the link roots, (link . target) each."
  (let (found)
    (dolist (root (link-roots) (nreverse found))
      (when (eq (kind root) :directory)
        (walk root (lambda (path kind)
                     (when (eq kind :link)
                       (push (cons path (target path)) found))))))))

(defun absolute (path)
  "PATH from the command line, absolute and normal; a link's target, if it's
one under the link roots."
  (when (string= path "") (error "an empty path"))
  (let ((p (normalize (if (char= (char path 0) #\/) path (join (sb-posix:getcwd) path)))))
    (if (and (eq (kind p) :link) (some (lambda (root) (under root p)) (link-roots)))
        (target p)
        p)))

(defun rule-path (path)
  "The path a rule for PATH, absolute, says: relative to *video*, or to the
seed tree for a shelf's."
  (let ((shelf (shelf-of path)))
    (cond (shelf (relative (dirname (car shelf)) path))
          ((and (under *video* path) (string/= path *video*)) (relative *video* path))
          (t (error "~a is in neither ~a nor a shelf's tree~@[ (~{~a~^, ~})~]"
                    path *video* (mapcar #'car *shelves*))))))

(defun rule-absolute (rule)
  "The absolute path RULE is for."
  (let ((shelf (find-if (lambda (shelf) (holds (basename (car shelf)) (first rule))) *shelves*)))
    (join (if shelf (dirname (car shelf)) *video*) (first rule))))

(defun rule-string (rule)
  "RULE as the rules file has it. Not printed readably, which prints the
base strings subseq makes as arrays."
  (with-standard-io-syntax
    (let ((*print-case* :downcase) (*print-readably* nil))
      (prin1-to-string rule))))

(defun write-rules (rules)
  (write-lines (cli-rules-file) (mapcar #'rule-string rules)))

(defun preference-p (rule)
  "Whether RULE only prefers; the command line's either do that or say where
a file goes."
  (equal (rest rule) '(:prefer t)))

(defun unlink-under (path)
  "Removes the links to files under PATH, or under PATH if it's a folder of
links, with the subtitles' beside their videos', and forgets them as
seconds, so the next run places them again. Says what it did, or would."
  (let* ((links (all-links))
         (held (lambda (link to) (or (under path to) (under path link))))
         (videos (loop for (link . to) in links
                       when (and (funcall held link to) (member (extension link) +videos+ :test #'string=))
                         collect link))
         (seconds (read-seconds))
         (gone (loop for (link . to) in links
                     when (or (funcall held link to)
                              (and (member (extension link) +subtitles+ :test #'string=)
                                   (some (lambda (video)
                                           (let ((stem (stem video)))
                                             (and (string= (dirname video) (dirname link))
                                                  (> (length link) (length stem))
                                                  (string= stem link :end2 (length stem))
                                                  (char= (char link (length stem)) #\.))))
                                         videos)))
                       collect link))
         (kept (remove-if (lambda (s) (or (under path (first s)) (under path (third s)))) seconds)))
    (dolist (link gone)
      (unless *dry-run* (sb-posix:unlink link))
      (say "~:[unlinked~;would unlink~] ~a" *dry-run* link))
    (when (/= (length kept) (length seconds))
      (say "~:[forgot~;would forget~] ~d cop~:@p kept out for a better one"
           *dry-run* (- (length seconds) (length kept)))
      (unless *dry-run* (write-seconds kept)))
    (unless *dry-run*
      (dolist (link gone)
        (prune (dirname link) (link-root link)))
      ;; jellyfin hears of it with the run that links them again
      (write-pending (remove-duplicates
                      (append (read-pending)
                              (mapcar (lambda (d) (cons "Deleted" d))
                                      (remove-if-not #'jellyfins (mapcar #'dirname gone))))
                      :test #'equal)))
    (when (and (null gone) (= (length kept) (length seconds)))
      (say "nothing under ~a was linked" path))))

(defun rerun ()
  "Starts odos's service, and shows what it did."
  (cond (*dry-run*)
        ((null *service*) (say "a run of odos places them"))
        (t (say "starting ~a" *service*)
           (let ((code (nth-value 2 (uiop:run-program (list "systemctl" "start" *service*)
                                                      :output :interactive :error-output :interactive
                                                      :ignore-error-status t)))
                 (id (string-trim '(#\Newline #\Space)
                                  (uiop:run-program (list "systemctl" "show" "--property=InvocationID"
                                                          "--value" *service*)
                                                    :output :string :ignore-error-status t))))
             (when (string/= id "")
               (uiop:run-program (list "journalctl" "--no-pager" "--output=cat"
                                       (format nil "_SYSTEMD_INVOCATION_ID=~a" id))
                                 :output :interactive :ignore-error-status t))
             (unless (zerop code)
               (say "~a didn't finish well; journalctl -u ~a says more" *service* *service*))))))

(defun change (path rule)
  "Adds RULE, the command line's, for PATH, in place of what they said of
it before (of where it goes, or of preferring it), and places what it holds
again."
  (with-lock
    (read-rules)
    (let ((rules (append (remove-if (lambda (r)
                                      (and (string= (first r) (first rule))
                                           (eq (preference-p r) (preference-p rule))))
                                    *cli-rules*)
                         (list rule))))
      (say "~:[~;would add ~]~a" *dry-run* (rule-string rule))
      (unless *dry-run* (write-rules rules)))
    (unlink-under path))
  (rerun))

(defun tmdb-name (kind id)
  "Says who tmdb's ID is, refusing an id it doesn't know."
  (let ((found (identify kind nil nil id)))
    (cond ((consp found) (say "~(~a~) ~a is ~a~@[ (~d)~]" kind id (second found) (third found)))
          ((eq found :none) (error "tmdb knows no ~(~a~) ~a" kind id))
          (t (say "jellyfin didn't answer, so ~(~a~) ~a is taken on trust" kind id)))))

(defun existing (arg)
  "ARG as an absolute path, which must be there."
  (let ((path (absolute arg)))
    (unless (kind path) (error "nothing at ~a" path))
    path))

(defun number-arg (s what)
  (or (and s (every #'digit-char-p s) (plusp (length s)) (parse-integer s))
      (error "~a should be a number, not ~:[nothing~;~:*~a~]" what s)))

(defun video-path (path)
  (when (shelf-of path) (error "~a is a shelf's, not a video's" path))
  (rule-path path))

;;; the commands

(defun cmd-place (kind args)
  "show PATH [tmdb] ID [season N [offset K]], film PATH [tmdb] ID, episode
FILE [tmdb] ID SEASON EP."
  (let* ((path (existing (or (pop args) (usage))))
         (rel (video-path path))
         (id (progn (when (equal (first args) "tmdb") (pop args))
                    (number-arg (pop args) "the tmdb id"))))
    (setup)
    (tmdb-name (if (eq kind :film) :film :show) id)
    (change path
            (ecase kind
              (:film (list rel :film id))
              (:show (if (null args)
                         (list rel :show id)
                         (let ((season (progn (unless (equal (pop args) "season") (usage))
                                              (number-arg (pop args) "the season")))
                               (offset (cond ((null args) 0)
                                             ((equal (pop args) "offset")
                                              (let ((k (pop args)))
                                                (if (and k (char= (char k 0) #\-))
                                                    (- (number-arg (subseq k 1) "the offset"))
                                                    (number-arg k "the offset"))))
                                             (t (usage)))))
                           (list rel :show id :episodes (list (list 1 nil season offset nil))))))
              (:episode
               (unless (eq (kind path) :file) (error "~a isn't a file" path))
               (list rel :show id :episode (list (number-arg (pop args) "the season")
                                                 (number-arg (pop args) "the episode"))))))))

(defun cmd-series (args)
  (let* ((path (existing (or (pop args) (usage))))
         (name (or (pop args) (usage))))
    (unless (shelf-of path) (error "~a isn't in a shelf's tree" path))
    (when (string= (clean name) "") (error "a series needs a name"))
    (read-rules)
    (change path (list (rule-path path) :series (clean name)))))

(defun cmd-ignore (args)
  (let ((path (existing (or (pop args) (usage)))))
    (read-rules)
    (change path (list (rule-path path) :ignore t))))

(defun cmd-prefer (args)
  (let ((path (existing (or (pop args) (usage)))))
    (read-rules)
    (change path (list (video-path path) :prefer t))))

(defun cmd-forget (args)
  "forget RULE: the command line's rules for a path, as `odos rules` prints it
or as a path."
  (let ((arg (or (pop args) (usage))))
    (with-lock
      (read-rules)
      (let* ((rel (if (find arg *cli-rules* :key #'first :test #'string=)
                      arg
                      (rule-path (absolute arg))))
             (gone (remove rel *cli-rules* :key #'first :test-not #'string=)))
        (unless gone
          (error "the command line has no rule for ~a~@[; nix's is in odos-rules.nix~]"
                 rel (find rel *nix-rules* :key #'first :test #'string=)))
        (dolist (r gone) (say "~:[~;would ~]forget ~a" *dry-run* (rule-string r)))
        (unless *dry-run*
          (write-rules (remove rel *cli-rules* :key #'first :test #'string=)))
        (unlink-under (rule-absolute (first gone)))))
    (rerun)))

(defun cmd-relink (args)
  (let ((path (existing (or (pop args) (usage)))))
    (with-lock (unlink-under path))
    (rerun)))

(defun group-of (link)
  "What LINK is listed under: its show's or film's folder, or its series'."
  (let ((root (find-if (lambda (root) (under root link))
                       (append (list *shows* *films*) (mapcar #'cdr *shelves*)))))
    (if root
        (join root (subseq (relative root link) 0 (position #\/ (relative root link))))
        (dirname link))))

(defun cmd-list (args)
  "list [--tmdb ID | --path P]: what's linked, by show, film or series."
  (let (tmdb path)
    (loop while args
          do (let ((flag (pop args)))
               (cond ((string= flag "--tmdb") (setf tmdb (princ-to-string (number-arg (pop args) "the tmdb id"))))
                     ((string= flag "--path") (setf path (absolute (or (pop args) (usage)))))
                     (t (usage)))))
    (let ((groups (make-hash-table :test 'equal))
          (seconds (settled (read-seconds))))
      (loop for (link . to) in (all-links)
            for group = (group-of link)
            when (and (or (null tmdb) (equal tmdb (let ((id (tmdb-of (basename group)))) (and id (aref id 0)))))
                      (or (null path) (under path to)))
              do (push (format nil "  ~a -> ~a" (relative group link) to) (gethash group groups)))
      (loop for (copy place) in seconds
            for group = (group-of place)
            when (and (member (extension copy) +videos+ :test #'string=)
                      (or (null tmdb) (equal tmdb (let ((id (tmdb-of (basename group)))) (and id (aref id 0)))))
                      (or (null path) (under path copy)))
              do (push (format nil "  ~a, kept out: ~a" (relative group place) copy) (gethash group groups)))
      (let ((names (sort (loop for g being the hash-keys of groups collect g) #'string<)))
        (unless names (say "nothing linked~@[ under ~a~]~@[ for tmdb ~a~]" path tmdb))
        (dolist (g names)
          (say "~a" (relative (dirname (dirname g)) g))
          (dolist (line (sort (gethash g groups) #'string<))
            (say "~a" line)))))))

(defun cmd-unsure ()
  (let ((unsure (read-pairs (join *state* "unsure"))))
    (unless unsure (say "nothing was left alone at the last run"))
    (loop for (why . path) in unsure
          do (say "~a~%  ~a" path why))))

(defun nix-string (s)
  (format nil "\"~a\"" (ppcre:regex-replace-all "([\"\\\\]|\\$\\{)" s "\\\\\\1")))

(defun nix-rule (rules)
  "RULES, all for one path, as one of odos.rules's attributes."
  (let (attrs)
    (dolist (r rules)
      (destructuring-bind (&key film show episodes episode series ignore prefer) (rest r)
        (when film (push (format nil "film = ~d;" film) attrs))
        (when show (push (format nil "show = ~d;" show) attrs))
        (when episode
          (push (format nil "episode = { season = ~d; number = ~d; };" (first episode) (second episode)) attrs))
        (cond ((and (= (length episodes) 1)
                    (destructuring-bind (from to season offset &optional parts) (first episodes)
                      (declare (ignore season offset))
                      (and (= from 1) (null to) (null parts))))
               (destructuring-bind (from to season offset &optional parts) (first episodes)
                 (declare (ignore from to parts))
                 (push (format nil "season = ~d;" season) attrs)
                 (unless (zerop offset) (push (format nil "offset = ~d;" offset) attrs))))
              (episodes
               (push (format nil "episodes = [~{ { ~{~a~^ ~} }~} ];"
                             (loop for (from to season offset parts) in episodes
                                   collect (remove nil (list (and (/= from 1) (format nil "from = ~d;" from))
                                                             (and to (format nil "to = ~d;" to))
                                                             (format nil "season = ~d;" season)
                                                             (and (/= offset 0) (format nil "offset = ~d;" offset))
                                                             (and parts "parts = true;")))))
                     attrs)))
        (when series (push (format nil "series = ~a;" (nix-string series)) attrs))
        (when ignore (push "ignore = true;" attrs))
        (when prefer (push "prefer = true;" attrs))))
    (format nil "~a = { ~{~a~^ ~} };" (nix-string (first (first rules))) (reverse attrs))))

(defun cmd-rules (args)
  "rules [--nix]: the command line's rules, then nix's; or the command line's
as nix, for odos-rules.nix."
  (read-rules)
  (cond ((equal args '("--nix"))
         (say "# odos's command line's rules, for odos.rules in lemma/odos-rules.nix")
         (let (paths)
           (dolist (r *cli-rules*) (pushnew (first r) paths :test #'string=))
           (dolist (p (reverse paths))
             (say "~a" (nix-rule (remove p *cli-rules* :key #'first :test-not #'string=))))))
        (args (usage))
        (t (unless *rules* (say "no rules"))
           (dolist (r *cli-rules*) (say "cli ~a" (rule-string r)))
           (dolist (r *nix-rules*) (say "nix ~a" (rule-string r))))))

(defun cmd-search (args)
  "search TITLE [--film] [--year Y]: what tmdb, through jellyfin, finds."
  (let (title film year)
    (loop while args
          do (let ((a (pop args)))
               (cond ((string= a "--film") (setf film t))
                     ((string= a "--year") (setf year (number-arg (pop args) "the year")))
                     (title (setf title (format nil "~a ~a" title a)))
                     (t (setf title a)))))
    (unless title (usage))
    (setup)
    (unless *key* (error "no api key to ask jellyfin with"))
    (let ((found (remote-search (if film :film :show) title year)))
      (cond ((eq found :unreachable) (error "jellyfin didn't answer"))
            ((null found) (say "tmdb knows no ~:[show~;film~] ~a" film title))
            (t (loop for (id name y) in found
                     do (say "~8a ~:[    ~;~:*~d~]  ~a  https://www.themoviedb.org/~:[tv~;movie~]/~a"
                             id y name film id)))))))

;;; resolve: a dry run of one file or folder, which says why

(defun reading (guess)
  "What guessit read, briefly."
  (format nil "~{~a~^, ~}"
          (loop for k in '("type" "title" "alternative_title" "year" "season" "episode" "part"
                           "episode_title" "subtitle_language" "release_group")
                for v = (gethash k guess)
                when (and v (not (eq v 'null)))
                  collect (format nil "~a ~a" k (jzon:stringify v)))))

(defun rule-source (rule)
  (if (member rule *cli-rules* :test #'eq) "the command line's" "nix's"))

(defun links-to ()
  "Every link's target, to the links to it."
  (let ((to (make-hash-table :test 'equal)))
    (loop for (link . target) in (all-links) do (push link (gethash target to)))
    to))

(defun resolve-video (files links seconds)
  (multiple-value-bind (guesses alones) (guess files)
    (let ((shows (folders *shows*)) (films (folders *films*))
          (run (make-run)) (dests (make-hash-table :test 'equal))
          ;; and where each goes
          (dests-of (make-hash-table :test 'equal)))
      (loop for f in files and g in guesses and a in alones
            do (say "~a" f)
               (say "  guessit reads ~a" (reading g))
               (say "  its name alone ~a" (reading a))
               (let ((rule (rule-for f)) (preference (preference f)))
                 (dolist (r (remove-duplicates (remove nil (list rule preference))))
                   (say "  rule, ~a: ~a" (rule-source r) (rule-string r)))
                 (unless rule
                   (let ((kind (reads-as g)) won)
                     (when kind
                       (dolist (c (titles g a))
                         (let ((found (identify kind (first c) (second c))))
                           (say "  tmdb ~(~a~) ~a~@[ (~d)~]: ~a~:[~; <- this~]"
                                kind (first c) (second c)
                                (cond ((consp found) (format nil "~a, ~a~@[ (~d)~]"
                                                             (first found) (second found) (third found)))
                                      ((eq found :none) "unknown")
                                      (t "jellyfin didn't answer"))
                                (and (consp found) (not won) (setf won t)))))))))
               (multiple-value-bind (stem key) (place f g a shows films)
                 (cond ((eq key :ignored) (say "  ignored"))
                       ((eq key :defer) (say "  waits until jellyfin answers"))
                       ((null stem) (say "  left alone: ~a" key))
                       (t (let* ((language (field g "subtitle_language"))
                                 (dest (if (member (extension f) +subtitles+ :test #'string=)
                                           (format nil "~a~@[.~a~].~a" stem (and (stringp language) language)
                                                   (extension f))
                                           (format nil "~a.~a" stem (extension f))))
                                 (there (linked-to run dest))
                                 (before (gethash dest dests)))
                            (say "  goes to ~a" dest)
                            (cond (before (say "  where ~a goes too" before))
                                  ((null there) (say "  which is free"))
                                  ((equal there f) (say "  which links to it already"))
                                  ((eq there :taken) (say "  where a file is, so it's left alone"))
                                  ((member (extension f) +subtitles+ :test #'string=)
                                   (say "  where ~a is linked" there))
                                  (t (multiple-value-bind (win why) (wins f there)
                                       (say "  where ~a is linked; ~:[that stays~;this wins~]: ~a"
                                            there win why))))
                            (setf (gethash dest dests) f (gethash f dests-of) dest)))))
               (let ((now (remove (gethash f dests-of) (gethash f links) :test #'equal))
                     (second (assoc f seconds :test #'equal)))
                 (when now
                   (say "  linked now from ~{~a~^, ~}~%  (a run passes over what's linked: odos relink places it again)" now))
                 (when second
                   (say "  kept out for the copy linked at ~a" (second second))))))))

(defun resolve-shelf (files links)
  (let ((indexes (make-hash-table :test 'equal)))
    (dolist (f files)
      (say "~a" f)
      (let* ((shelf (shelf-of f))
             (rule (rule-for f))
             (series (shelf-series f shelf)))
        (when rule (say "  rule, ~a: ~a" (rule-source rule) (rule-string rule)))
        (cond ((says rule :ignore) (say "  ignored"))
              ((null series) (say "  left alone: no series in its name or its folders'"))
              (t (let* ((library (cdr shelf))
                        (index (or (gethash library indexes)
                                   (setf (gethash library indexes) (folders library))))
                        (dest (join (join library (or (gethash (fold series) index) series))
                                    (basename f))))
                   (say "  series ~a, goes to ~a" series dest)
                   (case (kind dest)
                     ((nil) (say "  which is free"))
                     (:link (unless (equal (target dest) f)
                              (say "  where ~a is linked, so it's left alone" (target dest))))
                     (t (say "  where a file is, so it's left alone"))))))
        ;; but where it goes, which keeps its name
        (let ((now (remove (basename f) (gethash f links) :key #'basename :test #'string=)))
          (when now (say "  linked now from ~{~a~^, ~}" now)))))))

(defun cmd-resolve (args)
  "resolve PATH: what a run would make of a file or a folder's files, and why."
  (let* ((path (existing (or (pop args) (usage))))
         (*dry-run* t)
         (shelf (shelf-of path))
         (files (if (eq (kind path) :directory)
                    (let (found)
                      (walk path (lambda (p kind)
                                   (when (and (eq kind :file)
                                              (member (extension p)
                                                      (if shelf +shelf-files+ (append +videos+ +subtitles+))
                                                      :test #'string=)
                                              (or shelf (not (search "/sample" (string-downcase p)))))
                                     (push p found))))
                      (nreverse found))
                    (list path))))
    (rule-path path)
    (setup)
    (unless *key* (say "no api key: shows and films are named by guessit alone"))
    (unless files (say "no ~:[videos or subtitles~;files of a shelf's kinds~] under ~a" shelf path))
    (when files
      (if shelf
          (resolve-shelf files (links-to))
          (resolve-video files (links-to) (settled (read-seconds)))))))

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
