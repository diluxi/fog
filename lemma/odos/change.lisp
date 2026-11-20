;;;; odos: how the command line changes things: its rules, unlinking what
;;;; they hold, and starting the service

(in-package #:odos)

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
