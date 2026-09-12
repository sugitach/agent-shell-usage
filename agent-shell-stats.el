;;; agent-shell-stats.el --- Claude/Codex subscription usage in agent-shell mode-line -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;;
;; Author: generated for local use
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
;;
;; This file displays Claude Code and Codex subscription rate-limit usage in
;; agent-shell buffers.  It does NOT use ANTHROPIC_API_KEY or OPENAI_API_KEY.
;;
;; Claude:
;;   Requires wakamex/ccusage in PATH:
;;       uv tool install ccusage
;;   `ccusage json` reads the Claude Code OAuth subscription credentials.
;;
;; Codex:
;;   Requires `codex` in PATH and an existing ChatGPT login.
;;   Uses the local `codex app-server` JSON-RPC method:
;;       account/rateLimits/read
;;
;; Usage:
;;   (add-to-list 'load-path "/path/to/this/file")
;;   (require 'agent-shell-stats)
;;   (agent-shell-stats-mode 1)
;;
;; Optional:
;;   (setq agent-shell-stats-refresh-interval 120)
;;   (setq agent-shell-stats-display-as 'remaining) ; or 'used
;;   (setq agent-shell-stats-show-reset t)
;;
;; Commands:
;;   M-x agent-shell-stats-refresh
;;   M-x agent-shell-stats-show-details

;;; Code:

(require 'json)
(require 'subr-x)

(defgroup agent-shell-stats nil
  "Subscription usage display for coding agents."
  :group 'tools)

(defcustom agent-shell-stats-refresh-interval 120
  "Seconds between usage refreshes.
Both providers are refreshed asynchronously."
  :type 'integer
  :group 'agent-shell-stats)

(defcustom agent-shell-stats-display-as 'remaining
  "Whether percentages in the mode-line mean `remaining' or `used'."
  :type '(choice (const remaining) (const used))
  :group 'agent-shell-stats)

(defcustom agent-shell-stats-show-reset t
  "If non-nil, show compact time-to-reset after each percentage."
  :type 'boolean
  :group 'agent-shell-stats)

(defcustom agent-shell-stats-claude-command "ccusage"
  "Executable used to fetch Claude subscription usage."
  :type 'string
  :group 'agent-shell-stats)

(defcustom agent-shell-stats-codex-command "codex"
  "Codex CLI executable."
  :type 'string
  :group 'agent-shell-stats)

(defcustom agent-shell-stats-separator " | "
  "Separator between Claude and Codex usage."
  :type 'string
  :group 'agent-shell-stats)

(defvar agent-shell-stats--timer nil)
(defvar agent-shell-stats--claude nil)
(defvar agent-shell-stats--codex nil)
(defvar agent-shell-stats--claude-error nil)
(defvar agent-shell-stats--codex-error nil)
(defvar agent-shell-stats--last-refresh nil)
(defvar-local agent-shell-stats--installed-in-buffer nil)

(defun agent-shell-stats--jget (obj key)
  "Get KEY from JSON object OBJ parsed as an alist."
  (when (listp obj)
    (alist-get key obj)))

(defun agent-shell-stats--parse-json (text)
  (json-parse-string text
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object nil))

(defun agent-shell-stats--iso-to-time (iso)
  (when (and iso (stringp iso))
    (condition-case nil
        (date-to-time iso)
      (error nil))))

(defun agent-shell-stats--epoch-to-time (epoch)
  (when (numberp epoch)
    (seconds-to-time epoch)))

(defun agent-shell-stats--time-left (time)
  "Return compact duration from now until TIME."
  (when time
    (let ((seconds (max 0 (floor (float-time (time-subtract time (current-time)))))))
      (cond
       ((>= seconds 86400)
        (let ((days (/ seconds 86400))
              (hours (/ (% seconds 86400) 3600)))
          (if (> hours 0) (format "%dd%dh" days hours) (format "%dd" days))))
       ((>= seconds 3600)
        (format "%dh%02d" (/ seconds 3600) (/ (% seconds 3600) 60)))
       (t
        (format "%dm" (/ seconds 60)))))))

(defun agent-shell-stats--shown-percent (used)
  (when (numberp used)
    (round
     (if (eq agent-shell-stats-display-as 'remaining)
         (- 100 used)
       used))))

(defun agent-shell-stats--face-for-used (used)
  ;; Use standard semantic faces, not hard-coded colors.
  (cond ((not (numberp used)) 'shadow)
        ((>= used 90) 'error)
        ((>= used 70) 'warning)
        (t 'success)))

(defun agent-shell-stats--pct-string (used)
  (if (numberp used)
      (propertize (format "%d%%" (agent-shell-stats--shown-percent used))
                  'face (agent-shell-stats--face-for-used used))
    (propertize "?" 'face 'shadow)))

(defun agent-shell-stats--bucket-string (label bucket)
  (if (not bucket)
      (format "%s:?" label)
    (let* ((used (plist-get bucket :used))
           (reset (plist-get bucket :reset))
           (reset-str (and agent-shell-stats-show-reset
                           (agent-shell-stats--time-left reset))))
      (concat label ":" (agent-shell-stats--pct-string used)
              (if reset-str (concat "↻" reset-str) "")))))

(defun agent-shell-stats--claude-parse (text)
  "Parse `ccusage json` output TEXT."
  (let* ((obj (agent-shell-stats--parse-json text))
         ;; Current ccusage uses `session`; older cache versions used `5h`.
         (session (or (agent-shell-stats--jget obj 'session)
                      (agent-shell-stats--jget obj '5h)))
         (week (agent-shell-stats--jget obj '7d)))
    (list
     :plan (agent-shell-stats--jget obj 'plan)
     :session (when session
                (list :used (agent-shell-stats--jget session 'pct)
                      :reset (agent-shell-stats--iso-to-time
                              (agent-shell-stats--jget session 'resets_at))))
     :week (when week
             (list :used (agent-shell-stats--jget week 'pct)
                   :reset (agent-shell-stats--iso-to-time
                           (agent-shell-stats--jget week 'resets_at))))
     :updated (agent-shell-stats--jget obj 'updated_at))))

(defun agent-shell-stats--refresh-claude ()
  (if-let ((exe (executable-find agent-shell-stats-claude-command)))
      (let ((buf (generate-new-buffer " *agent-shell-stats-claude*")))
        (make-process
         :name "agent-shell-stats-claude"
         :buffer buf
         :command (list exe "json")
         :noquery t
         :connection-type 'pipe
         :sentinel
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (unwind-protect
                 (if (= (process-exit-status proc) 0)
                     (condition-case err
                         (progn
                           (setq agent-shell-stats--claude
                                 (agent-shell-stats--claude-parse
                                  (with-current-buffer (process-buffer proc)
                                    (buffer-string))))
                           (setq agent-shell-stats--claude-error nil))
                       (error
                        (setq agent-shell-stats--claude-error
                              (format "parse: %s" (error-message-string err)))))
                   (setq agent-shell-stats--claude-error
                         (string-trim
                          (with-current-buffer (process-buffer proc)
                            (buffer-string)))))
               (when (buffer-live-p (process-buffer proc))
                 (kill-buffer (process-buffer proc)))
               (force-mode-line-update t))))))
    (setq agent-shell-stats--claude-error
          (format "%s not found" agent-shell-stats-claude-command))))

(defun agent-shell-stats--codex-classify-window (window)
  "Convert a Codex WINDOW to (LABEL . PLIST), using its duration."
  (when window
    (let* ((mins (agent-shell-stats--jget window 'windowDurationMins))
           (used (agent-shell-stats--jget window 'usedPercent))
           (reset (agent-shell-stats--epoch-to-time
                   (agent-shell-stats--jget window 'resetsAt)))
           (label (cond ((equal mins 300) "5h")
                        ((equal mins 10080) "7d")
                        ((numberp mins) (format "%dm" mins))
                        (t "?"))))
      (cons label (list :used used :reset reset :minutes mins)))))

(defun agent-shell-stats--codex-parse-result (result)
  "Parse RESULT from account/rateLimits/read."
  (let* ((limits (agent-shell-stats--jget result 'rateLimits))
         (p (agent-shell-stats--codex-classify-window
             (agent-shell-stats--jget limits 'primary)))
         (s (agent-shell-stats--codex-classify-window
             (agent-shell-stats--jget limits 'secondary)))
         (windows (delq nil (list p s))))
    (list :plan (agent-shell-stats--jget limits 'planType)
          :windows windows
          :five (cdr (assoc "5h" windows))
          :week (cdr (assoc "7d" windows)))))

(defun agent-shell-stats--refresh-codex ()
  "Fetch Codex quota via the local official app-server protocol."
  (if-let ((exe (executable-find agent-shell-stats-codex-command)))
      (let* ((buf (generate-new-buffer " *agent-shell-stats-codex*"))
             (state (list :initialized nil :requested nil :done nil))
             (proc
              (make-process
               :name "agent-shell-stats-codex"
               :buffer buf
               :command (list exe "app-server")
               :coding 'utf-8-unix
               :connection-type 'pipe
               :noquery t
               :filter
               (lambda (p chunk)
                 ;; App-server is line-delimited JSON.  Preserve partial lines.
                 (let ((pending (concat (or (process-get p 'pending) "") chunk))
                       complete)
                   (while (string-match "\\`\\([^\n]*\\)\n" pending)
                     (push (match-string 1 pending) complete)
                     (setq pending (substring pending (match-end 0))))
                   (process-put p 'pending pending)
                   (dolist (line (nreverse complete))
                     (unless (string-empty-p line)
                       (condition-case nil
                           (let* ((msg (agent-shell-stats--parse-json line))
                                  (id (agent-shell-stats--jget msg 'id))
                                  (result (agent-shell-stats--jget msg 'result)))
                             (cond
                              ((and (equal id 1) result
                                    (not (plist-get state :requested)))
                               (setq state (plist-put state :initialized t))
                               ;; Complete the standard app-server handshake.
                               (process-send-string
                                p
                                (concat
                                 (json-serialize
                                  '((jsonrpc . "2.0")
                                    (method . "initialized")
                                    (params . nil)))
                                 "\n"))
                               (setq state (plist-put state :requested t))
                               (process-send-string
                                p
                                (concat
                                 (json-serialize
                                  '((jsonrpc . "2.0")
                                    (id . 2)
                                    (method . "account/rateLimits/read")
                                    (params . nil)))
                                 "\n")))
                              ((and (equal id 2) result)
                               (setq agent-shell-stats--codex
                                     (agent-shell-stats--codex-parse-result result))
                               (setq agent-shell-stats--codex-error nil)
                               (setq state (plist-put state :done t))
                               (delete-process p)
                               (force-mode-line-update t))
                              ((and (equal id 2) (agent-shell-stats--jget msg 'error))
                               (setq agent-shell-stats--codex-error
                                     (format "%S" (agent-shell-stats--jget msg 'error)))
                               (setq state (plist-put state :done t))
                               (delete-process p)
                               (force-mode-line-update t))))
                         (error nil))))))
               :sentinel
               (lambda (p _event)
                 (when (memq (process-status p) '(exit signal))
                   (unless (plist-get state :done)
                     (setq agent-shell-stats--codex-error
                           (string-trim
                            (with-current-buffer (process-buffer p)
                              (buffer-string)))))
                   (when (buffer-live-p (process-buffer p))
                     (kill-buffer (process-buffer p)))
                   (force-mode-line-update t))))))
        ;; Initialize app-server.  experimentalApi is harmless on versions that
        ;; no longer require it and helps compatibility with older versions.
        (process-send-string
         proc
         (concat
          (json-serialize
           '((jsonrpc . "2.0")
             (id . 1)
             (method . "initialize")
             (params .
                     ((clientInfo . ((name . "emacs-agent-shell-stats")
                                     (version . "1.0")))
                      (capabilities . ((experimentalApi . t)))))))
          "\n")))
    (setq agent-shell-stats--codex-error
          (format "%s not found" agent-shell-stats-codex-command))))

;;;###autoload
(defun agent-shell-stats-refresh ()
  "Refresh Claude and Codex subscription quotas asynchronously."
  (interactive)
  (setq agent-shell-stats--last-refresh (current-time))
  (agent-shell-stats--refresh-claude)
  (agent-shell-stats--refresh-codex))

(defun agent-shell-stats--provider-tooltip (name data error)
  (cond
   (error (format "%s usage unavailable: %s\nMouse-1: refresh" name error))
   ((not data) (format "%s usage: waiting for first refresh\nMouse-1: refresh" name))
   (t
    (let ((plan (or (plist-get data :plan) "?")))
      (format "%s (%s)\nDisplay: %s percentage\nMouse-1: refresh; Mouse-2: details"
              name plan agent-shell-stats-display-as)))))

(defun agent-shell-stats--claude-string ()
  (if agent-shell-stats--claude
      (let ((s (agent-shell-stats--bucket-string
                "S" (plist-get agent-shell-stats--claude :session)))
            (w (agent-shell-stats--bucket-string
                "W" (plist-get agent-shell-stats--claude :week))))
        (concat "C " s " " w))
    (propertize "C ?" 'face 'shadow)))

(defun agent-shell-stats--codex-string ()
  (if agent-shell-stats--codex
      (let ((five (plist-get agent-shell-stats--codex :five))
            (week (plist-get agent-shell-stats--codex :week))
            (windows (plist-get agent-shell-stats--codex :windows)))
        ;; If Codex changes its quotas, show every returned window rather than
        ;; silently pretending primary=5h and secondary=7d.
        (concat "X "
                (if (or five week)
                    (string-join
                     (delq nil
                           (list (and five (agent-shell-stats--bucket-string "5h" five))
                                 (and week (agent-shell-stats--bucket-string "7d" week))))
                     " ")
                  (string-join
                   (mapcar (lambda (x)
                             (agent-shell-stats--bucket-string (car x) (cdr x)))
                           windows)
                   " "))))
    (propertize "X ?" 'face 'shadow)))

(defvar agent-shell-stats--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1]
                (lambda (_event) (interactive) (agent-shell-stats-refresh)))
    (define-key map [mode-line mouse-2]
                (lambda (_event) (interactive) (agent-shell-stats-show-details)))
    map))

(defun agent-shell-stats--mode-line ()
  "Return cached usage text for the mode-line."
  (let* ((c (propertize
             (agent-shell-stats--claude-string)
             'help-echo (agent-shell-stats--provider-tooltip
                         "Claude" agent-shell-stats--claude agent-shell-stats--claude-error)
             'mouse-face 'mode-line-highlight
             'local-map agent-shell-stats--mode-line-map))
         (x (propertize
             (agent-shell-stats--codex-string)
             'help-echo (agent-shell-stats--provider-tooltip
                         "Codex" agent-shell-stats--codex agent-shell-stats--codex-error)
             'mouse-face 'mode-line-highlight
             'local-map agent-shell-stats--mode-line-map)))
    (concat " " c agent-shell-stats-separator x " ")))

(defun agent-shell-stats--install-here ()
  "Add the usage segment to the current agent-shell buffer."
  (unless agent-shell-stats--installed-in-buffer
    (setq-local agent-shell-stats--installed-in-buffer t)
    ;; `mode-line-format-right-align` is built into modern Emacs.  It inserts
    ;; flexible space so our segment naturally occupies the unused right side.
    (setq-local mode-line-format
                (append mode-line-format
                        '(mode-line-format-right-align
                          (:eval (agent-shell-stats--mode-line)))))))

(defun agent-shell-stats-show-details ()
  "Show the latest cached provider details."
  (interactive)
  (with-help-window "*Agent usage*"
    (princ (format "Percentages shown in mode-line: %s\n\n"
                   agent-shell-stats-display-as))
    (princ "Claude\n")
    (if agent-shell-stats--claude
        (pp agent-shell-stats--claude)
      (princ (format "  unavailable%s\n"
                     (if agent-shell-stats--claude-error
                         (concat ": " agent-shell-stats--claude-error) ""))))
    (princ "\nCodex\n")
    (if agent-shell-stats--codex
        (pp agent-shell-stats--codex)
      (princ (format "  unavailable%s\n"
                     (if agent-shell-stats--codex-error
                         (concat ": " agent-shell-stats--codex-error) ""))))
    (when agent-shell-stats--last-refresh
      (princ (format "\nLast refresh started: %s\n"
                     (format-time-string "%Y-%m-%d %H:%M:%S"
                                         agent-shell-stats--last-refresh))))))

(defun agent-shell-stats--start-timer ()
  (when (timerp agent-shell-stats--timer)
    (cancel-timer agent-shell-stats--timer))
  (setq agent-shell-stats--timer
        (run-at-time 0 agent-shell-stats-refresh-interval #'agent-shell-stats-refresh)))

(defun agent-shell-stats--stop-timer ()
  (when (timerp agent-shell-stats--timer)
    (cancel-timer agent-shell-stats--timer))
  (setq agent-shell-stats--timer nil))

;;;###autoload
(define-minor-mode agent-shell-stats-mode
  "Globally maintain subscription usage and display it in agent-shell buffers."
  :global t
  :group 'agent-shell-stats
  (if agent-shell-stats-mode
      (progn
        (add-hook 'agent-shell-mode-hook #'agent-shell-stats--install-here)
        ;; Install immediately in already-existing agent-shell buffers.
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when (derived-mode-p 'agent-shell-mode)
              (agent-shell-stats--install-here))))
        (agent-shell-stats--start-timer))
    (remove-hook 'agent-shell-mode-hook #'agent-shell-stats--install-here)
    (agent-shell-stats--stop-timer)))

(provide 'agent-shell-stats)

;;; agent-shell-stats.el ends here
