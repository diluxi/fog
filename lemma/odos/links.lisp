;;;; odos: what's linked already, and what isn't

(in-package #:odos)

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
