;;;; odos: where a video goes: its show's or film's folder, its season and episode

(in-package #:odos)

;;; where things go

(defun clean (title)
  "TITLE as a file name: no slashes, no dots or spaces at its ends."
  (let ((s (substitute #\Space #\/ title)))
    (string-trim " ." (with-output-to-string (o)
                        (loop for c across s and prev = nil then c
                              unless (and (char= c #\Space) (eql prev #\Space))
                                do (write-char c o))))))

(defun fold (name)
  "A folder name as compared: in lower case, without its tmdb id or (year)."
  (string-trim " " (ppcre:regex-replace-all "\\s*(\\[tmdbid-\\d+\\]|\\(\\d{4}\\))\\s*$"
                                            (ppcre:regex-replace-all "\\s*\\[tmdbid-\\d+\\]" (string-downcase name) "")
                                            "")))

(defun tmdb-of (name)
  (nth-value 1 (ppcre:scan-to-strings "\\[tmdbid-(\\d+)\\]" name)))

(defun folders (root)
  "ROOT's folders by their tmdb ids and by their folded names."
  (let ((index (make-hash-table :test 'equal)))
    (when (eq (kind root) :directory)
      (dolist (name (entries root))
        (when (eq (kind (join root name)) :directory)
          (let ((id (tmdb-of name)))
            (when id (setf (gethash (format nil "id:~a" (aref id 0)) index) name)))
          (setf (gethash (fold name) index) name))))
    index))

(defun folder (index kind candidates)
  "The folder a show or film has, or a new one, named by tmdb: for the first
of CANDIDATES, (title year) each, that tmdb knows. Its title is the second
value. nil when tmdb knows none of them, :defer when jellyfin can't be
asked. Without an api key nothing can be known, so it's named by the
first's title and year, as guessit read them."
  (if (null *key*)
      (destructuring-bind (title year) (first candidates)
        (values (or (gethash (fold title) index)
                    (setf (gethash (fold title) index)
                          (if year (format nil "~a (~d)" title year) title)))
                title))
      (dolist (candidate candidates nil)
        (let ((id (apply #'identify kind candidate)))
          (cond ((eq id :unreachable) (return :defer))
                ((consp id) (return (known-folder index id))))))))

(defun known-folder (index id)
  "The folder for ID, (tmdb name year), and its title."
  (destructuring-bind (tmdb name tmdb-year) id
    (let ((name (clean name)))
      (values (or (gethash (format nil "id:~a" tmdb) index)
                  (let ((new (format nil "~a~@[ (~d)~] [tmdbid-~a]" name tmdb-year tmdb)))
                    (setf (gethash (format nil "id:~a" tmdb) index) new
                          (gethash (fold new) index) new)))
              name))))

(defun numbers (path guess)
  "The episode numbers PATH holds: guessit's, or the one before \" - \" in its
name (Owarimonogatari 2nd Season 01 - Mayoi Hell)."
  (or (remove-if-not #'integerp (fields guess "episode"))
      (let ((m (nth-value 1 (ppcre:scan-to-strings "(\\d{1,3}) - " (basename path)))))
        (and m (list (parse-integer (aref m 0)))))))

(defun episode-place (folder name season episodes &optional part)
  (values (format nil "~a/~a/Season ~2,'0d/~a S~2,'0dE~{~2,'0d~^-E~}~@[ - part~d~]"
                  *shows* folder season name season episodes part)
          (list* :episode (fold folder) season episodes (and part (list part)))))

(defun place-by-rule (rule path guess shows films)
  (destructuring-bind (prefix &key film show episodes episode ignore &allow-other-keys) rule
    (declare (ignore prefix))
    (flet ((by-id (index kind id)
             (let ((found (identify kind nil nil id)))
               (cond ((eq found :unreachable) (return-from place-by-rule (values nil :defer)))
                     ((consp found) (known-folder index found))
                     (t (return-from place-by-rule
                          (values nil (format nil "tmdb doesn't know the rule's ~(~a~) ~a" kind id))))))))
      (cond (ignore (values nil :ignored))
            (film
             (let ((folder (by-id films :film film)))
               (values (format nil "~a/~a/~a" *films* folder folder) (list :film (fold folder)))))
            ((and show episode)
             (multiple-value-bind (folder name) (by-id shows :show show)
               (episode-place folder name (first episode) (list (second episode)))))
            ((and show (null episodes))
             (let ((season (let ((v (field guess "season"))) (and (integerp v) v)))
                   (ns (numbers path guess)))
               (cond ((null ns) (values nil "no episode number for the rule"))
                     ((null season) (values nil "no season in its name, nor in the rule"))
                     (t (multiple-value-bind (folder name) (by-id shows :show show)
                          (episode-place folder name season ns))))))
            (show
             (let* ((ns (numbers path guess))
                    (segment (and ns (find-if (lambda (seg)
                                                (destructuring-bind (from to &rest _) seg
                                                  (declare (ignore _))
                                                  (and (>= (first ns) from) (or (null to) (<= (first ns) to)))))
                                              episodes))))
               (cond ((null ns) (values nil "no episode number for the rule"))
                     ((null segment) (values nil (format nil "the rule has no season for episode ~d" (first ns))))
                     (t (destructuring-bind (from to season offset &optional parts) segment
                          (declare (ignore to))
                          (multiple-value-bind (folder name) (by-id shows :show show)
                            (let ((eps (if parts
                                           (list (+ from offset))
                                           (mapcar (lambda (n) (+ n offset)) ns)))
                                  (part (and parts (1+ (- (first ns) from)))))
                              (episode-place folder name season eps part))))))))
            (t (values nil "a rule that says neither film nor show"))))))

(defun title-and-year (guess)
  "(title year) as GUESS has them, or nil without a title."
  (let ((title (let ((v (field guess "title"))) (and (stringp v) (clean v))))
        (year (let ((v (field guess "year"))) (and (integerp v) v))))
    (and title (string/= title "") (list title year))))

(defun titles (guess alone)
  "Who a file may be, (title year) each, first as GUESS has it, then as
ALONE has it."
  (remove-duplicates (remove nil (list (title-and-year guess) (title-and-year alone)))
                     :test #'equal :from-end t
                     :key (lambda (c) (list (fold (first c)) (second c)))))

(defun reads-as (guess)
  "What GUESS reads a file as: :show or :film, or nil. An \"episode\" with
neither season nor number is a film whose name has a word guessit takes for
an episode's (Blade.Runner.Final.Cut)."
  (let ((type (field guess "type")))
    (cond ((and (equal type "episode")
                (or (integerp (field guess "season"))
                    (some #'integerp (fields guess "episode"))))
           :show)
          ((member type '("movie" "episode") :test #'equal) :film))))

(defun place (path guess alone shows films)
  "Where PATH, which GUESS is of, goes, without its extension, and its key for
subtitles; or nil and why not, or nil and :defer when jellyfin can't say who
it is yet. A rule for it goes first. Who it is is the title GUESS has, or
else the one ALONE has, guessit's reading of the file's name alone; what
season and episode, GUESS's. SHOWS and FILMS index their roots' folders."
  (let ((rule (rule-for path)))
    (when rule
      (return-from place (place-by-rule rule path guess shows films))))
  (let ((candidates (titles guess alone))
        (season (let ((v (field guess "season"))) (and (integerp v) v)))
        (episodes (remove-if-not #'integerp (fields guess "episode"))))
    (flet ((unknown ()
             (values nil (format nil "tmdb knows no ~{~a~^ or ~}"
                                 (mapcar (lambda (c) (format nil "~a~@[ (~d)~]" (first c) (second c)))
                                         candidates)))))
    (cond ((null candidates) (values nil "no title"))
          ((eq (reads-as guess) :show)
           (cond ((null episodes) (values nil "an episode without its number"))
                 ((null season) (values nil "an episode without a season (absolute numbering?)"))
                 (t (multiple-value-bind (show name) (folder shows :show candidates)
                      (cond ((eq show :defer) (values nil :defer))
                            ((null show) (unknown))
                            (t (episode-place show name season episodes)))))))
          ((eq (reads-as guess) :film)
           (let ((film (folder films :film candidates)))
             (cond ((eq film :defer) (values nil :defer))
                   ((null film) (unknown))
                   (t (values (format nil "~a/~a/~a" *films* film film)
                              (list :film (fold film)))))))
          (t (values nil (format nil "neither episode nor film: ~a" (field guess "type"))))))))
