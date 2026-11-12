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

;;; the run

(defstruct run
  (linked 0) (upgraded 0) (unsure '()) (changed '()) (seconds '())
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
        (t (ensure-directories (dirname dest) *links*)
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
    (dolist (name (entries dir) dropped)
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
          (t (multiple-value-bind (win why) (better target there)
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

(defun torrent (path)
  "The torrent PATH came with, as far as the seed tree says: the folder at its
top, or nothing for a file there on its own."
  (let* ((rel (relative *video* path)) (slash (position #\/ rel)))
    (if slash (subseq rel 0 slash) "")))

(defun link-all (run paths)
  (let* ((guesses (guess paths))
         (shows (folders *shows*))
         (films (folders *films*))
         ;; what became of each video, by what it is and the torrent it came
         ;; with, for its subtitles: where it's linked, or (:second place video)
         (stems (make-hash-table :test 'equal)))
    ;; videos first, so subtitles find where theirs went
    (loop for path in paths and g in guesses
          when (member (extension path) +videos+ :test #'string=)
            do (unless (find "Sample" (fields g "other") :test #'equal)
                 (multiple-value-bind (stem key) (place g shows films)
                   (if (null stem)
                       (note-unsure run path key)
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
                                    (list :second dest path))))))))))
    (loop for path in paths and g in guesses
          when (member (extension path) +subtitles+ :test #'string=)
            do (multiple-value-bind (stem key) (place g shows films)
                 (let ((stem (and stem (gethash (cons key (torrent path)) stems)))
                       (language (field g "subtitle_language")))
                   (cond ((stringp stem)
                          (put run path (format nil "~a~@[.~a~].~a" stem
                                                (and (stringp language) language)
                                                (extension path))))
                         ((consp stem)
                          (destructuring-bind (dest video) (rest stem)
                            (push (list path dest video) (run-seconds run))))))))))

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
    (let* ((run (make-run))
           (seconds (settled (read-seconds)))
           (paths (remove-if (lambda (p) (assoc p seconds :test #'equal))
                             (candidates linked))))
      (when paths (link-all run paths))
      (unless *dry-run*
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
