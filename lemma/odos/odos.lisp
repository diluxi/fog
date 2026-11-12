;;;; odos, the way from a torrent to a library: every video under the seed
;;;; tree that nothing links to yet is read by guessit and linked where
;;;; jellyfin expects it, shows as TV/Show (Year)/Season 02/Show S02E05.mkv
;;;; and films as Films/Title (Year)/Title (Year).mkv, subtitles beside
;;;; their video. links whose torrent went are removed. what guessit can't
;;;; place surely is listed instead, for linking by hand, and jellyfin is
;;;; told which folders changed.
;;;;
;;;; paths are native strings throughout, never pathnames: torrent names
;;;; are full of brackets and stars, which pathnames read as wildcards

(defpackage #:odos
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:export #:main))

(in-package #:odos)

(defvar *video* "/srv/seed/video" "What's linked to.")
(defvar *links* "/srv/kino" "Where links are looked for, which take a file.")
(defvar *shows* "/srv/kino/TV")
(defvar *films* "/srv/kino/Films")
(defvar *state* "/var/lib/odos" "pending, what jellyfin hasn't heard yet; unsure, what odos left alone.")
(defvar *spool* nil "Emptied first: the done-hook's markers, which only say to run.")
(defvar *jellyfin* "http://127.0.0.1:8096")
(defvar *key-file* nil "Jellyfin's api key, or nothing to tell it.")
(defvar *dry-run* nil "Say what would be linked, and change nothing.")

(defparameter +videos+
  '("mkv" "mp4" "m4v" "avi" "mov" "wmv" "webm" "ts" "m2ts" "mpg" "mpeg" "flv" "ogv"))
(defparameter +subtitles+ '("srt" "ass" "ssa" "vtt" "sub" "idx" "sup" "smi"))

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

(defun survey ()
  "The targets linked to from anywhere under *links*, as a set, after links
into *video* whose file is gone are removed. Returns the folders that lost
one as the second value."
  (let ((linked (make-hash-table :test 'equal)) gone)
    (walk *links*
          (lambda (path kind)
            (when (eq kind :link)
              (let ((to (target path)))
                (cond ((or (not (under *video* to)) (exists to))
                       (setf (gethash to linked) t))
                      (*dry-run* (say "would remove ~a, its file is gone" path))
                      (t (sb-posix:unlink path)
                         (say "removed ~a, its file is gone" path)
                         (push path gone)))))))
    (dolist (link gone)
      (prune (dirname link) *links*))
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

(defun guess (paths)
  "What guessit makes of each path, relative to *video* so a torrent's
folder names help, as hash tables in the same order."
  (when paths
    (let ((out (with-output-to-string (s)
                 (with-input-from-string (in (format nil "~{~a~%~}"
                                                     (mapcar (lambda (p) (relative *video* p)) paths)))
                   (uiop:run-program '("guessit" "--json" "--input-file" "/dev/stdin")
                                     :input in :output s :error-output *error-output*)))))
      (let ((lines (remove "" (uiop:split-string out :separator '(#\Newline)) :test #'string=)))
        (unless (= (length lines) (length paths))
          (error "guessit answered ~d times for ~d names" (length lines) (length paths)))
        (mapcar #'jzon:parse lines)))))

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

;;; where things go

(defun clean (title)
  "TITLE as a file name: no slashes, no dots or spaces at its ends."
  (let ((s (substitute #\Space #\/ title)))
    (string-trim " ." (with-output-to-string (o)
                        (loop for c across s and prev = nil then c
                              unless (and (char= c #\Space) (eql prev #\Space))
                                do (write-char c o))))))

(defun fold (name)
  "A folder name as compared: in lower case, without a trailing (year)."
  (let ((n (string-downcase name)))
    (if (and (> (length n) 7) (char= (char n (- (length n) 1)) #\))
             (string= " (" n :start2 (- (length n) 7) :end2 (- (length n) 5))
             (every #'digit-char-p (subseq n (- (length n) 5) (- (length n) 1))))
        (subseq n 0 (- (length n) 7))
        n)))

(defun folders (root)
  "ROOT's folders by their folded names, so a show keeps the folder it has,
with or without a year."
  (let ((index (make-hash-table :test 'equal)))
    (when (eq (kind root) :directory)
      (dolist (name (entries root))
        (when (eq (kind (join root name)) :directory)
          (setf (gethash (fold name) index) name))))
    index))

(defun folder (index title year)
  "The folder a show or film has, or a new one, named with its year if
guessit found one."
  (or (gethash (fold title) index)
      (setf (gethash (fold title) index)
            (if year (format nil "~a (~d)" title year) title))))

(defun place (guess shows films)
  "Where the video GUESS is of goes, without its extension, and its key for
subtitles; or nil and why not. SHOWS and FILMS index their roots' folders."
  (let ((title (let ((v (field guess "title"))) (and (stringp v) (clean v))))
        (year (let ((v (field guess "year"))) (and (integerp v) v)))
        (season (let ((v (field guess "season"))) (and (integerp v) v)))
        (episodes (remove-if-not #'integerp (fields guess "episode"))))
    (cond ((or (null title) (string= title "")) (values nil "no title"))
          ((string= (field guess "type") "episode")
           (cond ((null episodes) (values nil "an episode without its number"))
                 ((null season) (values nil "an episode without a season (absolute numbering?)"))
                 (t (let ((show (folder shows title year)))
                      (values (format nil "~a/~a/Season ~2,'0d/~a S~2,'0dE~{~2,'0d~^-E~}"
                                      *shows* show season title season episodes)
                              (list :episode (fold show) season episodes))))))
          ((string= (field guess "type") "movie")
           (let ((film (folder films title year)))
             (values (format nil "~a/~a/~a" *films* film film)
                     (list :film (fold film)))))
          (t (values nil (format nil "neither episode nor film: ~a" (field guess "type")))))))

;;; the run

(defstruct run
  (linked 0) (unsure '()) (changed '()))

(defun note-unsure (run path why)
  (push (cons path why) (run-unsure run)))

(defun put (run target dest)
  "Links DEST to TARGET. A place taken by something else is left as it is."
  (case (kind dest)
    ((nil)
     (cond (*dry-run* (say "would link ~a -> ~a" dest target))
           (t (ensure-directories (dirname dest) *links*)
              (sb-posix:symlink target dest)
              (say "~a -> ~a" dest target)
              (push (dirname dest) (run-changed run))))
     (incf (run-linked run))
     t)
    (:link (or (string= (target dest) target)
               (progn (note-unsure run target (format nil "~a links elsewhere" dest)) nil)))
    (t (note-unsure run target (format nil "~a is taken" dest)) nil)))

(defun link-all (run paths)
  (let* ((guesses (guess paths))
         (shows (folders *shows*))
         (films (folders *films*))
         (stems (make-hash-table :test 'equal)))
    ;; videos first, so subtitles find where theirs went
    (loop for path in paths and g in guesses
          when (member (extension path) +videos+ :test #'string=)
            do (if (find "Sample" (fields g "other") :test #'equal)
                   nil
                   (multiple-value-bind (stem key) (place g shows films)
                     (cond ((null stem) (note-unsure run path key))
                           ((put run path (format nil "~a.~a" stem (extension path)))
                            (setf (gethash key stems) stem))))))
    (loop for path in paths and g in guesses
          when (member (extension path) +subtitles+ :test #'string=)
            do (multiple-value-bind (stem key) (place g shows films)
                 (let ((stem (and stem (gethash key stems)))
                       (language (field g "subtitle_language")))
                   (when stem
                     (put run path (format nil "~a~@[.~a~].~a" stem
                                           (and (stringp language) language)
                                           (extension path)))))))))

;;; jellyfin

(defun quoted (s)
  "S as a string in curl's config syntax."
  (with-output-to-string (o)
    (write-char #\" o)
    (loop for c across s
          do (when (member c '(#\" #\\)) (write-char #\\ o))
             (write-char c o))
    (write-char #\" o)))

(defun tell (updates key)
  "Tells jellyfin about UPDATES, (type . path) each, through curl, whose
config comes on stdin so the key is on no command line. True if it took
them."
  (let ((body (jzon:stringify
               (let ((h (make-hash-table :test 'equal)))
                 (setf (gethash "Updates" h)
                       (coerce (loop for (type . path) in updates
                                     collect (let ((u (make-hash-table :test 'equal)))
                                               (setf (gethash "Path" u) path
                                                     (gethash "UpdateType" u) type)
                                               u))
                               'vector))
                 h))))
    (with-input-from-string
        (in (format nil "url = ~a~%header = ~a~%header = \"Content-Type: application/json\"~%data = ~a~%fail~%silent~%show-error~%"
                    (quoted (format nil "~a/Library/Media/Updated" *jellyfin*))
                    (quoted (format nil "Authorization: MediaBrowser Token=\"~a\"" key))
                    (quoted body)))
      (zerop (nth-value 2 (uiop:run-program '("curl" "--config" "-") :input in :output nil
                                            :error-output *error-output* :ignore-error-status t))))))

(defun pending-file () (join *state* "pending"))

(defun read-pending ()
  (with-open-file (in (pending-file) :if-does-not-exist nil :external-format :utf-8)
    (when in
      (loop for line = (read-line in nil)
            while line
            for tab = (position #\Tab line)
            when tab collect (cons (subseq line 0 tab) (subseq line (1+ tab)))))))

(defun write-lines (file lines)
  (with-open-file (out (concatenate 'string file ".new") :direction :output
                       :if-exists :supersede :external-format :utf-8)
    (dolist (l lines) (format out "~a~%" l)))
  ;; not rename-file, which would give the new name the old one's type
  (sb-posix:rename (concatenate 'string file ".new") file))

(defun write-pending (updates)
  (write-lines (pending-file) (loop for (type . path) in updates collect (format nil "~a~c~a" type #\Tab path))))

(defun report (run gone)
  "What changed is added to what jellyfin hasn't heard yet, which is told.
False if jellyfin couldn't be reached, and it's kept for next time."
  (let* ((updates (remove-duplicates
                   (append (read-pending)
                           (mapcar (lambda (d) (cons "Created" d)) (run-changed run))
                           (mapcar (lambda (d) (cons "Deleted" d)) gone))
                   :test #'equal))
         (key (and *key-file* (probe-file *key-file*)
                   (string-trim '(#\Space #\Newline #\Tab) (uiop:read-file-string *key-file*)))))
    (cond ((or (null updates) *dry-run*) t)
          ((null key) (say "no api key, so jellyfin finds these on its next scan") t)
          ((tell updates key)
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

(defun odos ()
  "One run. True unless jellyfin is owed a report it couldn't take."
  (empty-spool)
  (unless *dry-run*
    (dolist (root (list *shows* *films*))
      (ensure-directories root *links*)))
  (multiple-value-bind (linked gone) (survey)
    (let ((run (make-run))
          (paths (candidates linked)))
      (when paths (link-all run paths))
      (unless *dry-run*
        (write-lines (join *state* "unsure")
                     (loop for (path . why) in (reverse (run-unsure run))
                           collect (format nil "~a~c~a" why #\Tab path))))
      (say "~d linked, ~d left for linking by hand~@[ (~a)~]"
           (run-linked run) (length (run-unsure run))
           (and (run-unsure run) (join *state* "unsure")))
      (report run gone))))

(defun usage ()
  (format *error-output* "usage: odos [--dry-run] [--video DIR] [--links DIR] [--shows DIR] [--films DIR]
            [--state DIR] [--spool DIR] [--jellyfin URL] [--key-file FILE]~%")
  (uiop:quit 64))

(defun main ()
  (setf sb-alien::*default-c-string-external-format* :utf-8
        sb-impl::*default-external-format* :utf-8)
  (let ((args (rest sb-ext:*posix-argv*)))
    (loop while args
          do (let ((flag (pop args)))
               (if (string= flag "--dry-run")
                   (setf *dry-run* t)
                   (let ((value (or (pop args) (usage))))
                     (cond ((string= flag "--video") (setf *video* value))
                           ((string= flag "--links") (setf *links* value))
                           ((string= flag "--shows") (setf *shows* value))
                           ((string= flag "--films") (setf *films* value))
                           ((string= flag "--state") (setf *state* value))
                           ((string= flag "--spool") (setf *spool* value))
                           ((string= flag "--jellyfin") (setf *jellyfin* value))
                           ((string= flag "--key-file") (setf *key-file* value))
                           (t (usage))))))))
  (handler-case (uiop:quit (if (odos) 0 75))
    (error (e)
      (format *error-output* "odos: ~a~%" e)
      (uiop:quit 1))))
