;;;; odos: what a run keeps between runs: seconds, and what jellyfin is owed

(in-package #:odos)

;;; telling jellyfin

(defun tell (updates)
  "Tells jellyfin about UPDATES, (type . path) each. True if it took them."
  (jellyfin "/Library/Media/Updated"
            (object "Updates" (coerce (loop for (type . path) in updates
                                            collect (object "Path" path "UpdateType" type))
                                      'vector))))

(defun pending-file () (join *state* "pending"))

(defun read-pending () (read-pairs (pending-file)))

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
