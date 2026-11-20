;;;; odos: which of two copies of one episode or film is linked

(in-package #:odos)

;;; which of two copies is better
;;;
;;; by what the files are, as ffprobe reads them, not by their names: guessit
;;; doesn't know av1, and names are what a release says of itself. compared
;;; key by key, the first difference deciding:
;;;
;;;   1. resolution, as a tier: 2160p, 1440p, 1080p, ... a cropped 1920x800
;;;      is 1080p
;;;   2. codec, by how much picture it keeps per bit: av1, hevc, vp9, h264,
;;;      vc1, mpeg-2 and mpeg-4, anything else
;;;   3. bit depth: 10 bits over 8, fewer bands in gradients
;;;   4. hdr over sdr
;;;   5. with all that equal, so the same codec at the same size: the video's
;;;      bit rate, measured over the same stretch of both, since they're the
;;;      same episode or film. it wins only by more than a sixth, so encodes
;;;      about as good don't swap, and the one that's linked stays
;;;
;;; a copy ffprobe can't read loses to one it can.

(defparameter +tiers+ '(4320 2160 1440 1080 720 576 480 360 240))
(defparameter +codecs+ '("av1" "hevc" "vp9" "h264" "vc1" ("mpeg2video" "mpeg4")))
(defparameter +margin+ 7/6 "How much more bit rate a copy needs to beat the linked one.")
(defparameter +stretch+ '(120 30) "Where bit rates are measured: from 2:00, for 30 s.")

(defun ffprobe (&rest args)
  (multiple-value-bind (out err code)
      (uiop:run-program (cons "ffprobe" (list* "-v" "error" args))
                        :output :string :error-output nil :ignore-error-status t)
    (declare (ignore err))
    (and (zerop code) out)))

(defun probe (path)
  "PATH's video as ffprobe reads it: (tier codec depth hdr width height fps
duration), or nil."
  (let* ((out (ffprobe "-print_format" "json" "-show_format" "-show_streams"
                       (concatenate 'string "file:" path)))
         (json (and out (ignore-errors (jzon:parse out))))
         (video (and json
                     (find-if (lambda (s)
                                (and (equal (gethash "codec_type" s) "video")
                                     ;; not cover art
                                     (not (eql 1 (gethash "attached_pic" (gethash "disposition" s))))))
                              (gethash "streams" json)))))
    (when video
      (let* ((w (or (number-in (gethash "width" video)) 0))
             (h (or (number-in (gethash "height" video)) 0))
             (size (max h (* w 9/16)))
             (pix (gethash "pix_fmt" video))
             (transfer (gethash "color_transfer" video)))
        (list :tier (or (find-if (lambda (tier) (>= size (* tier 19/20))) +tiers+) 0)
              :codec (let ((c (gethash "codec_name" video)))
                       (- (length +codecs+)
                          (or (position-if (lambda (k) (if (listp k) (member c k :test #'equal) (equal c k)))
                                           +codecs+)
                              (length +codecs+))))
              :depth (if (and (stringp pix) (search "10" pix)) 10 8)
              :hdr (if (member transfer '("smpte2084" "arib-std-b67") :test #'equal) 1 0)
              :name (format nil "~dp ~a~:[~; 10-bit~]~:[~; hdr~]"
                            (or (find-if (lambda (tier) (>= size (* tier 19/20))) +tiers+) h)
                            (gethash "codec_name" video)
                            (and (stringp pix) (search "10" pix))
                            (member transfer '("smpte2084" "arib-std-b67") :test #'equal))
              :duration (number-in (gethash "duration" (gethash "format" json))))))))

(defun bit-rate (path duration)
  "Bits a second of PATH's video over +stretch+, or from the start if it's
shorter; nil if ffprobe can't say."
  (destructuring-bind (from span) +stretch+
    (let* ((from (if (and duration (> duration (+ from span))) from 0))
           (out (ffprobe "-select_streams" "v:0" "-read_intervals" (format nil "~d%+~d" from span)
                         "-show_entries" "packet=size,pts_time" "-of" "csv=p=0"
                         (concatenate 'string "file:" path)))
           (packets (and out (loop for line in (uiop:split-string out :separator '(#\Newline))
                                   for (time size) = (uiop:split-string line :separator ",")
                                   for tn = (number-in time) and sn = (number-in size)
                                   when (and tn sn) collect (cons tn sn)))))
      (when (cdr packets)
        (let ((first (reduce #'min packets :key #'car))
              (last (reduce #'max packets :key #'car)))
          (when (> last first)
            (/ (* 8 (reduce #'+ packets :key #'cdr)) (- last first))))))))

(defun better (new old)
  "Whether the copy at NEW beats the one at OLD, and why, as a string."
  (let ((a (probe new)) (b (probe old)))
    (cond ((null a) (values nil "ffprobe can't read it"))
          ((null b) (values t "ffprobe can't read the linked one"))
          (t (loop for key in '(:tier :codec :depth :hdr)
                   for x = (getf a key) and y = (getf b key)
                   when (/= x y)
                     do (return-from better
                          (values (> x y) (format nil "~a ~:[loses to~;over~] ~a"
                                                  (getf a :name) (> x y) (getf b :name)))))
             (let ((x (bit-rate new (getf a :duration)))
                   (y (bit-rate old (getf b :duration))))
               (cond ((or (null x) (null y)) (values nil "bit rates unknown, the linked one stays"))
                     (t (let ((win (> x (* y +margin+))))
                          (values win (format nil "~a at ~,1f Mbit/s ~:[stays behind~;over~] ~,1f Mbit/s"
                                              (getf a :name) (/ x 1000000) win (/ y 1000000)))))))))))

(defun wins (new old)
  "Whether the copy at NEW beats the one at OLD, and why: a rule's preference
first, then which is better."
  (let ((a (preference new)) (b (and (under *video* old) (preference old))))
    (cond ((and a (not b)) (values t (format nil "a rule prefers it (~s)" (first a))))
          ((and b (not a)) (values nil (format nil "a rule prefers the linked one (~s)" (first b))))
          (t (better new old)))))
