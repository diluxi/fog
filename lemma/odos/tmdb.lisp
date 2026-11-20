;;;; odos: jellyfin, and through it tmdb: who a show or film is

(in-package #:odos)

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
