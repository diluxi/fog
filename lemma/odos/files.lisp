;;;; odos: paths as strings, the file system through sb-posix, odos's state files, and the lock

(in-package #:odos)

;;; paths

(defun join (dir name)
  (if (string= dir "/") (concatenate 'string "/" name) (concatenate 'string dir "/" name)))

(defun dirname (path)
  (let ((slash (position #\/ path :from-end t)))
    (cond ((null slash) ".") ((zerop slash) "/") (t (subseq path 0 slash)))))

(defun basename (path)
  (subseq path (1+ (or (position #\/ path :from-end t) -1))))

(defun extension (path)
  (let* ((name (basename path)) (dot (position #\. name :from-end t)))
    (and dot (plusp dot) (string-downcase (subseq name (1+ dot))))))

(defun normalize (path)
  "PATH without . and .., lexically: what a link's target means."
  (let (parts)
    (dolist (p (uiop:split-string path :separator "/"))
      (cond ((member p '("" ".") :test #'string=))
            ((string= p "..") (pop parts))
            (t (push p parts))))
    (format nil "/~{~a~^/~}" (reverse parts))))

(defun under (root path)
  "Whether PATH is ROOT or inside it."
  (let ((n (length root)))
    (and (>= (length path) n) (string= root path :end2 n)
         (or (= (length path) n) (char= (char path n) #\/)))))

(defun relative (root path)
  (subseq path (min (length path) (1+ (length root)))))

;;; the file system, through sb-posix

(defun kind (path)
  "What PATH is, not following a link: :directory, :file, :link, :other, or
nil when there's nothing."
  (handler-case
      (let ((type (logand (sb-posix:stat-mode (sb-posix:lstat path)) sb-posix:s-ifmt)))
        (cond ((= type sb-posix:s-ifdir) :directory)
              ((= type sb-posix:s-ifreg) :file)
              ((= type sb-posix:s-iflnk) :link)
              (t :other)))
    (sb-posix:syscall-error () nil)))

(defun exists (path)
  "Whether PATH is there, following links."
  (handler-case (progn (sb-posix:stat path) t)
    (sb-posix:syscall-error () nil)))

(defun entries (dir)
  (let ((d (sb-posix:opendir dir)) names)
    (unwind-protect
         (loop for e = (sb-posix:readdir d)
               until (sb-alien:null-alien e)
               do (let ((name (sb-posix:dirent-name e)))
                    (unless (member name '("." "..") :test #'string=)
                      (push name names))))
      (sb-posix:closedir d))
    (sort names #'string<)))

(defun walk (root fn)
  "Calls FN with every path under ROOT and its kind, not following links. A
directory that can't be read is said and passed over."
  (dolist (name (handler-case (entries root)
                  ;; unreadable, or a name that isn't utf-8
                  (error (e)
                    (say "can't read ~a: ~a" root e)
                    nil)))
    (let* ((path (join root name)) (kind (kind path)))
      (funcall fn path kind)
      (when (eq kind :directory) (walk path fn)))))

(defun ensure-directories (path root)
  "Makes PATH and what's missing above it, up to ROOT, which must exist."
  (unless (or (string= path root) (kind path))
    (ensure-directories (dirname path) root)
    (sb-posix:mkdir path #o770)))

(defun prune (dir root)
  "Removes DIR if it's empty, and so on upwards, short of ROOT."
  (when (and (under root dir) (not (string= dir root))
             (eq (kind dir) :directory) (null (entries dir)))
    (sb-posix:rmdir dir)
    (prune (dirname dir) root)))

(defun read-pairs (file)
  "FILE's lines as (a . b), from a<tab>b; nothing if there's no FILE."
  (when (eq (kind file) :file)
    (with-open-file (in file :external-format :utf-8)
      (loop for line = (read-line in nil)
            while line
            for tab = (position #\Tab line)
            when tab collect (cons (subseq line 0 tab) (subseq line (1+ tab)))))))

(defun write-lines (file lines)
  (with-open-file (out (concatenate 'string file ".new") :direction :output
                       :if-exists :supersede :external-format :utf-8)
    (dolist (l lines) (format out "~a~%" l)))
  ;; root, odos's command line, keeps what it writes odos's
  (when (zerop (sb-posix:getuid))
    (let ((dir (sb-posix:stat (dirname file))))
      (sb-posix:chown (concatenate 'string file ".new")
                      (sb-posix:stat-uid dir) (sb-posix:stat-gid dir))))
  ;; not rename-file, which would give the new name the old one's type
  (sb-posix:rename (concatenate 'string file ".new") file))

(defun write-pairs (file pairs)
  (write-lines file (loop for (a . b) in pairs collect (format nil "~a~c~a" a #\Tab b))))

(defun lock ()
  "Waits until no other odos changes *state* or the links, and keeps others
waiting until the descriptor it returns is closed, or odos exits."
  (let ((fd (sb-posix:open *state* sb-posix:o-rdonly)))
    (unless (zerop (sb-alien:alien-funcall
                    (sb-alien:extern-alien "flock" (function sb-alien:int sb-alien:int sb-alien:int))
                    fd 2))                ; LOCK_EX
      (sb-posix:close fd)
      (error "can't lock ~a" *state*))
    fd))

(defmacro with-lock (&body body)
  (let ((fd (gensym)))
    `(let ((,fd (lock)))
       (unwind-protect (progn ,@body) (sb-posix:close ,fd)))))
