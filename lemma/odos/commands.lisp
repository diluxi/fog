;;;; odos: the command line's commands, but resolve

(in-package #:odos)

;;; the commands

(defun cmd-place (kind args)
  "show PATH [tmdb] ID [season N [offset K]], film PATH [tmdb] ID, episode
FILE [tmdb] ID SEASON EP."
  (let* ((path (existing (or (pop args) (usage))))
         (rel (video-path path))
         (id (progn (when (equal (first args) "tmdb") (pop args))
                    (number-arg (pop args) "the tmdb id"))))
    (setup)
    (tmdb-name (if (eq kind :film) :film :show) id)
    (change path
            (ecase kind
              (:film (list rel :film id))
              (:show (if (null args)
                         (list rel :show id)
                         (let ((season (progn (unless (equal (pop args) "season") (usage))
                                              (number-arg (pop args) "the season")))
                               (offset (cond ((null args) 0)
                                             ((equal (pop args) "offset")
                                              (let ((k (pop args)))
                                                (if (and k (char= (char k 0) #\-))
                                                    (- (number-arg (subseq k 1) "the offset"))
                                                    (number-arg k "the offset"))))
                                             (t (usage)))))
                           (list rel :show id :episodes (list (list 1 nil season offset nil))))))
              (:episode
               (unless (eq (kind path) :file) (error "~a isn't a file" path))
               (list rel :show id :episode (list (number-arg (pop args) "the season")
                                                 (number-arg (pop args) "the episode"))))))))

(defun cmd-series (args)
  (let* ((path (existing (or (pop args) (usage))))
         (name (or (pop args) (usage))))
    (unless (shelf-of path) (error "~a isn't in a shelf's tree" path))
    (when (string= (clean name) "") (error "a series needs a name"))
    (read-rules)
    (change path (list (rule-path path) :series (clean name)))))

(defun cmd-ignore (args)
  (let ((path (existing (or (pop args) (usage)))))
    (read-rules)
    (change path (list (rule-path path) :ignore t))))

(defun cmd-prefer (args)
  (let ((path (existing (or (pop args) (usage)))))
    (read-rules)
    (change path (list (video-path path) :prefer t))))

(defun cmd-forget (args)
  "forget RULE: the command line's rules for a path, as `odos rules` prints it
or as a path."
  (let ((arg (or (pop args) (usage))))
    (with-lock
      (read-rules)
      (let* ((rel (if (find arg *cli-rules* :key #'first :test #'string=)
                      arg
                      (rule-path (absolute arg))))
             (gone (remove rel *cli-rules* :key #'first :test-not #'string=)))
        (unless gone
          (error "the command line has no rule for ~a~@[; nix's is in odos-rules.nix~]"
                 rel (find rel *nix-rules* :key #'first :test #'string=)))
        (dolist (r gone) (say "~:[~;would ~]forget ~a" *dry-run* (rule-string r)))
        (unless *dry-run*
          (write-rules (remove rel *cli-rules* :key #'first :test #'string=)))
        (unlink-under (rule-absolute (first gone)))))
    (rerun)))

(defun cmd-relink (args)
  (let ((path (existing (or (pop args) (usage)))))
    (with-lock (unlink-under path))
    (rerun)))

(defun group-of (link)
  "What LINK is listed under: its show's or film's folder, or its series'."
  (let ((root (find-if (lambda (root) (under root link))
                       (append (list *shows* *films*) (mapcar #'cdr *shelves*)))))
    (if root
        (join root (subseq (relative root link) 0 (position #\/ (relative root link))))
        (dirname link))))

(defun cmd-list (args)
  "list [--tmdb ID | --path P]: what's linked, by show, film or series."
  (let (tmdb path)
    (loop while args
          do (let ((flag (pop args)))
               (cond ((string= flag "--tmdb") (setf tmdb (princ-to-string (number-arg (pop args) "the tmdb id"))))
                     ((string= flag "--path") (setf path (absolute (or (pop args) (usage)))))
                     (t (usage)))))
    (let ((groups (make-hash-table :test 'equal))
          (seconds (settled (read-seconds))))
      (loop for (link . to) in (all-links)
            for group = (group-of link)
            when (and (or (null tmdb) (equal tmdb (let ((id (tmdb-of (basename group)))) (and id (aref id 0)))))
                      (or (null path) (under path to)))
              do (push (format nil "  ~a -> ~a" (relative group link) to) (gethash group groups)))
      (loop for (copy place) in seconds
            for group = (group-of place)
            when (and (member (extension copy) +videos+ :test #'string=)
                      (or (null tmdb) (equal tmdb (let ((id (tmdb-of (basename group)))) (and id (aref id 0)))))
                      (or (null path) (under path copy)))
              do (push (format nil "  ~a, kept out: ~a" (relative group place) copy) (gethash group groups)))
      (let ((names (sort (loop for g being the hash-keys of groups collect g) #'string<)))
        (unless names (say "nothing linked~@[ under ~a~]~@[ for tmdb ~a~]" path tmdb))
        (dolist (g names)
          (say "~a" (relative (dirname (dirname g)) g))
          (dolist (line (sort (gethash g groups) #'string<))
            (say "~a" line)))))))

(defun cmd-unsure ()
  (let ((unsure (read-pairs (join *state* "unsure"))))
    (unless unsure (say "nothing was left alone at the last run"))
    (loop for (why . path) in unsure
          do (say "~a~%  ~a" path why))))

(defun nix-string (s)
  (format nil "\"~a\"" (ppcre:regex-replace-all "([\"\\\\]|\\$\\{)" s "\\\\\\1")))

(defun nix-rule (rules)
  "RULES, all for one path, as one of odos.rules's attributes."
  (let (attrs)
    (dolist (r rules)
      (destructuring-bind (&key film show episodes episode series ignore prefer) (rest r)
        (when film (push (format nil "film = ~d;" film) attrs))
        (when show (push (format nil "show = ~d;" show) attrs))
        (when episode
          (push (format nil "episode = { season = ~d; number = ~d; };" (first episode) (second episode)) attrs))
        (cond ((and (= (length episodes) 1)
                    (destructuring-bind (from to season offset &optional parts) (first episodes)
                      (declare (ignore season offset))
                      (and (= from 1) (null to) (null parts))))
               (destructuring-bind (from to season offset &optional parts) (first episodes)
                 (declare (ignore from to parts))
                 (push (format nil "season = ~d;" season) attrs)
                 (unless (zerop offset) (push (format nil "offset = ~d;" offset) attrs))))
              (episodes
               (push (format nil "episodes = [~{ { ~{~a~^ ~} }~} ];"
                             (loop for (from to season offset parts) in episodes
                                   collect (remove nil (list (and (/= from 1) (format nil "from = ~d;" from))
                                                             (and to (format nil "to = ~d;" to))
                                                             (format nil "season = ~d;" season)
                                                             (and (/= offset 0) (format nil "offset = ~d;" offset))
                                                             (and parts "parts = true;")))))
                     attrs)))
        (when series (push (format nil "series = ~a;" (nix-string series)) attrs))
        (when ignore (push "ignore = true;" attrs))
        (when prefer (push "prefer = true;" attrs))))
    (format nil "~a = { ~{~a~^ ~} };" (nix-string (first (first rules))) (reverse attrs))))

(defun cmd-rules (args)
  "rules [--nix]: the command line's rules, then nix's; or the command line's
as nix, for odos-rules.nix."
  (read-rules)
  (cond ((equal args '("--nix"))
         (say "# odos's command line's rules, for odos.rules in lemma/odos-rules.nix")
         (let (paths)
           (dolist (r *cli-rules*) (pushnew (first r) paths :test #'string=))
           (dolist (p (reverse paths))
             (say "~a" (nix-rule (remove p *cli-rules* :key #'first :test-not #'string=))))))
        (args (usage))
        (t (unless *rules* (say "no rules"))
           (dolist (r *cli-rules*) (say "cli ~a" (rule-string r)))
           (dolist (r *nix-rules*) (say "nix ~a" (rule-string r))))))

(defun cmd-search (args)
  "search TITLE [--film] [--year Y]: what tmdb, through jellyfin, finds."
  (let (title film year)
    (loop while args
          do (let ((a (pop args)))
               (cond ((string= a "--film") (setf film t))
                     ((string= a "--year") (setf year (number-arg (pop args) "the year")))
                     (title (setf title (format nil "~a ~a" title a)))
                     (t (setf title a)))))
    (unless title (usage))
    (setup)
    (unless *key* (error "no api key to ask jellyfin with"))
    (let ((found (remote-search (if film :film :show) title year)))
      (cond ((eq found :unreachable) (error "jellyfin didn't answer"))
            ((null found) (say "tmdb knows no ~:[show~;film~] ~a" film title))
            (t (loop for (id name y) in found
                     do (say "~8a ~:[    ~;~:*~d~]  ~a  https://www.themoviedb.org/~:[tv~;movie~]/~a"
                             id y name film id)))))))
