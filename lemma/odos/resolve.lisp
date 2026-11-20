;;;; odos: resolve: a dry run of one path, which says why

(in-package #:odos)

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
