;;;; odos: what guessit makes of names

(in-package #:odos)

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
