;;;; odos: a run: linking what isn't linked

(in-package #:odos)

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

(defun empty-spool ()
  (when (and *spool* (eq (kind *spool*) :directory))
    (dolist (name (entries *spool*))
      (handler-case (sb-posix:unlink (join *spool* name))
        (sb-posix:syscall-error () nil)))))

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
