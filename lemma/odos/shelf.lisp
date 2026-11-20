;;;; odos: the shelf: manga, comics and books, for kavita

(in-package #:odos)

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
