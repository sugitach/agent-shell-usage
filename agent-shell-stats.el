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
;;   Reuses Claude Code's own OAuth credentials directly: the on-disk
;;   ~/.claude/.credentials.json file if present, otherwise (macOS only)
;;   the "Claude Code-credentials" Keychain item, then calls Anthropic's
;;   `/api/oauth/usage` endpoint.  No extra tool required.
;;
;; Codex:
;;   Requires `codex` in PATH and an existing ChatGPT login.
;;   Uses the local `codex app-server` JSON-RPC method:
;;       account/rateLimits/read
;;
;; Antigravity (agy):
;;   Requires `agy` in PATH and an existing Antigravity login.
;;   Runs `agy -p "/quota" --output-format json` non-interactively, which
;;   reports two weekly quota groups: Gemini models, and Claude+GPT models
;;   (Claude Sonnet/Opus and GPT-OSS share a single quota bucket).
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

(defcustom agent-shell-stats-debug nil
  "If non-nil, log refresh events to the *agent-shell-stats-debug* buffer."
  :type 'boolean
  :group 'agent-shell-stats)

(defun agent-shell-stats--log (fmt &rest args)
  "Append a timestamped line to *agent-shell-stats-debug* when debugging."
  (when agent-shell-stats-debug
    (with-current-buffer (get-buffer-create "*agent-shell-stats-debug*")
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S.%3N] ")
              (apply #'format fmt args)
              "\n"))))

(defcustom agent-shell-stats-display-as 'remaining
  "Whether percentages in the mode-line mean `remaining' or `used'."
  :type '(choice (const remaining) (const used))
  :group 'agent-shell-stats)

(defcustom agent-shell-stats-show-reset t
  "If non-nil, show compact time-to-reset after each percentage."
  :type 'boolean
  :group 'agent-shell-stats)

(defcustom agent-shell-stats-claude-keychain-service "Claude Code-credentials"
  "macOS Keychain service name Claude Code stores its OAuth token under."
  :type 'string
  :group 'agent-shell-stats)

(defcustom agent-shell-stats-claude-keychain-account (user-login-name)
  "macOS Keychain account name for `agent-shell-stats-claude-keychain-service'."
  :type 'string
  :group 'agent-shell-stats)

(defcustom agent-shell-stats-claude-user-agent "claude-code/2.1.71"
  "User-Agent header sent to Anthropic's usage endpoint."
  :type 'string
  :group 'agent-shell-stats)

(defconst agent-shell-stats--claude-client-id
  "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  "Claude Code's public OAuth client id.")

(defconst agent-shell-stats--claude-token-url
  "https://console.anthropic.com/v1/oauth/token")

(defconst agent-shell-stats--claude-usage-url
  "https://api.anthropic.com/api/oauth/usage")

(defcustom agent-shell-stats-codex-command "codex"
  "Codex CLI executable."
  :type 'string
  :group 'agent-shell-stats)

(defcustom agent-shell-stats-agy-command "agy"
  "Antigravity CLI executable."
  :type 'string
  :group 'agent-shell-stats)

(defcustom agent-shell-stats-separator " | "
  "Separator between Claude, Codex, and Antigravity usage."
  :type 'string
  :group 'agent-shell-stats)

(defvar agent-shell-stats--timer nil)
(defvar agent-shell-stats--claude nil)
(defvar agent-shell-stats--codex nil)
(defvar agent-shell-stats--agy nil)
(defvar agent-shell-stats--claude-error nil)
(defvar agent-shell-stats--codex-error nil)
(defvar agent-shell-stats--agy-error nil)
(defvar agent-shell-stats--last-refresh nil)
(defvar agent-shell-stats--codex-process nil
  "The in-flight `codex app-server' process, if any.
Tracked so a slow refresh can be killed before starting a new one instead
of racing it.")
(defvar agent-shell-stats--codex-generation 0
  "Bumped on every Codex refresh so a stale, late-arriving response
from a superseded refresh can be told apart from the current one and
ignored instead of overwriting fresher data.")
(defvar agent-shell-stats--agy-process nil
  "The in-flight `agy' quota-fetch process, if any.
Tracked so a slow refresh can be killed before starting a new one instead
of racing it.")
(defvar agent-shell-stats--agy-generation 0
  "Bumped on every Antigravity refresh so a stale, late-arriving response
from a superseded refresh can be told apart from the current one and
ignored instead of overwriting fresher data.")
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

(defun agent-shell-stats--time-left (time &optional scale)
  "Return a fixed-width duration string from now until TIME.
SCALE is `short' (HhMMm, for session/5h windows, hours always 1 digit,
minutes always 2 digits), `long' (DdHHh, for week/7d windows, days
always 1 digit, hours always 2 digits), or nil to pick a format from
the magnitude of TIME."
  (when time
    (let ((seconds (max 0 (floor (float-time (time-subtract time (current-time)))))))
      (cond
       ((eq scale 'short)
        (format "%dh%02dm" (/ seconds 3600) (/ (% seconds 3600) 60)))
       ((eq scale 'long)
        (format "%dd%02dh" (/ seconds 86400) (/ (% seconds 86400) 3600)))
       ((>= seconds 86400)
        (let ((days (/ seconds 86400))
              (hours (/ (% seconds 86400) 3600)))
          (if (> hours 0) (format "%dd%dh" days hours) (format "%dd" days))))
       ((>= seconds 3600)
        (format "%dh%02dm" (/ seconds 3600) (/ (% seconds 3600) 60)))
       (t
        (format "%dm" (/ seconds 60)))))))

(defun agent-shell-stats--time-left-placeholder (scale)
  "Return a dashed placeholder the same width as `agent-shell-stats--time-left'.
Used when nothing has been used yet, so a countdown to the window's
reset would just be noise that keeps ticking down for no reason."
  (cond ((eq scale 'short) "-h--m")
        ((eq scale 'long) "-d--h")
        (t "-")))

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
  ;; The mode-line reprocesses %-constructs in eval'd strings, so a literal
  ;; "%" must be doubled here to survive as a single "%" on screen.  Digits
  ;; are space-padded to line up with a 3-digit "100%".
  (if (numberp used)
      (propertize (format "%3d%%%%" (agent-shell-stats--shown-percent used))
                  'face (agent-shell-stats--face-for-used used))
    (propertize "  ?" 'face 'shadow)))

(defun agent-shell-stats--bucket-string (label bucket &optional scale)
  (if (not bucket)
      (format "%s:?" label)
    (let* ((used (plist-get bucket :used))
           (reset (plist-get bucket :reset))
           (reset-str (and agent-shell-stats-show-reset
                           (if (and (numberp used) (= used 0))
                               (agent-shell-stats--time-left-placeholder scale)
                             (agent-shell-stats--time-left reset scale)))))
      (concat label ":" (agent-shell-stats--pct-string used)
              (if reset-str (concat "↻" reset-str) "")))))

(defun agent-shell-stats--claude-credentials-file ()
  (expand-file-name ".credentials.json" "~/.claude/"))

(defun agent-shell-stats--claude-read-file ()
  "Read Claude Code OAuth credentials from ~/.claude/.credentials.json."
  (let ((file (agent-shell-stats--claude-credentials-file)))
    (when (file-readable-p file)
      (condition-case nil
          (agent-shell-stats--jget
           (agent-shell-stats--parse-json
            (with-temp-buffer
              (insert-file-contents file)
              (buffer-string)))
           'claudeAiOauth)
        (error nil)))))

(defun agent-shell-stats--claude-write-file (oauth)
  (with-temp-file (agent-shell-stats--claude-credentials-file)
    (insert (json-serialize (list (cons 'claudeAiOauth oauth))))))

(defun agent-shell-stats--claude-read-keychain ()
  "Read Claude Code OAuth credentials from the macOS Keychain."
  (with-temp-buffer
    (when (zerop (call-process "security" nil t nil
                               "find-generic-password" "-s"
                               agent-shell-stats-claude-keychain-service "-w"))
      (condition-case nil
          (agent-shell-stats--jget
           (agent-shell-stats--parse-json (string-trim (buffer-string)))
           'claudeAiOauth)
        (error nil)))))

(defun agent-shell-stats--claude-write-keychain (oauth)
  "Persist refreshed OAUTH credentials back to the Keychain."
  (call-process "security" nil nil nil
                "add-generic-password" "-U"
                "-a" agent-shell-stats-claude-keychain-account
                "-s" agent-shell-stats-claude-keychain-service
                "-w" (json-serialize (list (cons 'claudeAiOauth oauth)))))

(defun agent-shell-stats--claude-read-credentials ()
  "Return (SOURCE . OAUTH) for Claude Code's OAuth credentials, or nil.
SOURCE is `file' or `keychain', identifying where refreshed tokens must
be written back.  Prefers the on-disk credentials file used on Linux and
Windows; falls back to the macOS Keychain, where Claude Code stores
credentials by default on that platform."
  (or (let ((oauth (agent-shell-stats--claude-read-file)))
        (when oauth (cons 'file oauth)))
      (when (eq system-type 'darwin)
        (let ((oauth (agent-shell-stats--claude-read-keychain)))
          (when oauth (cons 'keychain oauth))))))

(defun agent-shell-stats--claude-write-credentials (source oauth)
  (if (eq source 'file)
      (agent-shell-stats--claude-write-file oauth)
    (agent-shell-stats--claude-write-keychain oauth)))

(defun agent-shell-stats--alist-merge (base overrides)
  "Return alist BASE with keys in OVERRIDES replaced or added."
  (append overrides (seq-remove (lambda (kv) (assq (car kv) overrides)) base)))

(defun agent-shell-stats--curl-json (url method headers data callback)
  "Run curl asynchronously and call CALLBACK with (HTTP-STATUS . BODY).
HTTP-STATUS is nil if curl itself failed to run or returned no status."
  (if-let ((exe (executable-find "curl")))
      (let* ((buf (generate-new-buffer " *agent-shell-stats-curl*"))
             (args (append (list "-s" "-w" "\n%{http_code}" "-X" method)
                           (mapcan (lambda (h) (list "-H" h)) headers)
                           (when data (list "-d" data))
                           (list url))))
        (make-process
         :name "agent-shell-stats-curl"
         :buffer buf
         :command (cons exe args)
         :noquery t
         :connection-type 'pipe
         :sentinel
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (unwind-protect
                 (let* ((output (with-current-buffer (process-buffer proc) (buffer-string)))
                        (idx (and (= (process-exit-status proc) 0)
                                  (string-match "\n\\([0-9]+\\)\\'" output))))
                   (if idx
                       (funcall callback (string-to-number (match-string 1 output))
                                (substring output 0 idx))
                     (funcall callback nil (string-trim output))))
               (when (buffer-live-p (process-buffer proc))
                 (kill-buffer (process-buffer proc))))))))
    (funcall callback nil "curl not found")))

(defun agent-shell-stats--claude-parse-usage (data oauth)
  "Convert Anthropic's /api/oauth/usage response DATA into our display plist."
  (let (session week)
    (dolist (entry (agent-shell-stats--jget data 'limits))
      (let* ((kind (agent-shell-stats--jget entry 'kind))
             (bucket (list :used (agent-shell-stats--jget entry 'percent)
                           :reset (agent-shell-stats--iso-to-time
                                   (agent-shell-stats--jget entry 'resets_at)))))
        (cond ((equal kind "session") (setq session bucket))
              ((equal kind "weekly_all") (setq week bucket)))))
    (list :plan (or (agent-shell-stats--jget oauth 'rateLimitTier)
                     (agent-shell-stats--jget oauth 'subscriptionType))
          :session session
          :week week)))

(defun agent-shell-stats--claude-fetch-usage (oauth)
  "Fetch subscription usage using OAUTH's access token."
  (if-let ((token (agent-shell-stats--jget oauth 'accessToken)))
      (agent-shell-stats--curl-json
       agent-shell-stats--claude-usage-url "GET"
       (list (format "Authorization: Bearer %s" token)
             "anthropic-beta: oauth-2025-04-20"
             "Content-Type: application/json"
             (concat "User-Agent: " agent-shell-stats-claude-user-agent))
       nil
       (lambda (code body)
         (if (eql code 200)
             (condition-case err
                 (progn
                   (setq agent-shell-stats--claude
                         (agent-shell-stats--claude-parse-usage
                          (agent-shell-stats--parse-json body) oauth))
                   (setq agent-shell-stats--claude-error nil))
               (error
                (setq agent-shell-stats--claude-error
                      (format "parse: %s" (error-message-string err)))))
           (setq agent-shell-stats--claude-error
                 (format "usage fetch failed (%s): %s" (or code "?") body)))
         (force-mode-line-update t)))
    (setq agent-shell-stats--claude-error "no access token in credentials")))

(defun agent-shell-stats--claude-refresh-token (source oauth continue)
  "Refresh an expired Claude OAuth token, persist it, then call CONTINUE."
  (if-let ((refresh-token (agent-shell-stats--jget oauth 'refreshToken)))
      (agent-shell-stats--curl-json
       agent-shell-stats--claude-token-url "POST"
       '("Content-Type: application/json")
       (json-serialize `((grant_type . "refresh_token")
                         (refresh_token . ,refresh-token)
                         (client_id . ,agent-shell-stats--claude-client-id)))
       (lambda (code body)
         (if (eql code 200)
             (condition-case err
                 (let* ((result (agent-shell-stats--parse-json body))
                        (updated
                         (agent-shell-stats--alist-merge
                          oauth
                          (list (cons 'accessToken (agent-shell-stats--jget result 'access_token))
                                (cons 'refreshToken
                                      (or (agent-shell-stats--jget result 'refresh_token)
                                          refresh-token))
                                (cons 'expiresAt
                                      (round (+ (* (float-time) 1000)
                                                (* (or (agent-shell-stats--jget result 'expires_in) 3600)
                                                   1000))))))))
                   (agent-shell-stats--claude-write-credentials source updated)
                   (funcall continue updated))
               (error
                (setq agent-shell-stats--claude-error
                      (format "token refresh parse: %s" (error-message-string err)))
                (force-mode-line-update t)))
           (setq agent-shell-stats--claude-error
                 (format "token refresh failed (%s)" (or code "?")))
           (force-mode-line-update t))))
    (setq agent-shell-stats--claude-error
          "no refresh token in credentials; run `claude` to log in")))

(defun agent-shell-stats--refresh-claude ()
  "Fetch Claude Code subscription usage using its own OAuth credentials."
  (if-let ((creds (agent-shell-stats--claude-read-credentials)))
      (let* ((source (car creds))
             (oauth (cdr creds))
             (expires-at (agent-shell-stats--jget oauth 'expiresAt)))
        (if (and (numberp expires-at)
                 (> (* (float-time) 1000) (- expires-at 60000)))
            (agent-shell-stats--claude-refresh-token
             source oauth #'agent-shell-stats--claude-fetch-usage)
          (agent-shell-stats--claude-fetch-usage oauth)))
    (setq agent-shell-stats--claude-error
          (if (eq system-type 'darwin)
              "no credentials file or Keychain entry found; run `claude` first"
            "no credentials file found; run `claude` first"))))

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
  ;; A slow prior refresh (e.g. a cold `codex app-server' start) can still be
  ;; in flight when the timer fires again.  Kill it instead of letting two
  ;; requests race — whichever response arrived last used to win, which could
  ;; briefly overwrite fresh data with a stale value and flicker the mode-line.
  (when (process-live-p agent-shell-stats--codex-process)
    (agent-shell-stats--log "refresh-codex: killing still-live previous process")
    (delete-process agent-shell-stats--codex-process))
  (if-let ((exe (executable-find agent-shell-stats-codex-command)))
      (let* ((generation (setq agent-shell-stats--codex-generation
                                (1+ agent-shell-stats--codex-generation)))
             (_ (agent-shell-stats--log "refresh-codex: start generation=%d exe=%s" generation exe))
             (buf (generate-new-buffer " *agent-shell-stats-codex*"))
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
                       (agent-shell-stats--log "codex gen=%d recv: %s" generation line)
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
                               ;; Ignore a response from a refresh that's since
                               ;; been superseded by a newer one.
                               (if (= generation agent-shell-stats--codex-generation)
                                   (let ((parsed (agent-shell-stats--codex-parse-result result)))
                                     (agent-shell-stats--log
                                      "codex gen=%d APPLYING parsed=%S" generation parsed)
                                     (setq agent-shell-stats--codex parsed)
                                     (setq agent-shell-stats--codex-error nil))
                                 (agent-shell-stats--log
                                  "codex gen=%d DISCARDED (current-gen=%d)"
                                  generation agent-shell-stats--codex-generation))
                               (setq state (plist-put state :done t))
                               (delete-process p)
                               (force-mode-line-update t))
                              ((and (equal id 2) (agent-shell-stats--jget msg 'error))
                               (when (= generation agent-shell-stats--codex-generation)
                                 (setq agent-shell-stats--codex-error
                                       (format "%S" (agent-shell-stats--jget msg 'error))))
                               (setq state (plist-put state :done t))
                               (delete-process p)
                               (force-mode-line-update t))))
                         (error nil))))))
               :sentinel
               (lambda (p event)
                 (when (memq (process-status p) '(exit signal))
                   (agent-shell-stats--log
                    "codex gen=%d sentinel event=%s done=%s current-gen=%d"
                    generation (string-trim event) (plist-get state :done)
                    agent-shell-stats--codex-generation)
                   (when (and (not (plist-get state :done))
                              (= generation agent-shell-stats--codex-generation))
                     (setq agent-shell-stats--codex-error
                           (string-trim
                            (with-current-buffer (process-buffer p)
                              (buffer-string)))))
                   (when (buffer-live-p (process-buffer p))
                     (kill-buffer (process-buffer p)))
                   (force-mode-line-update t))))))
        (setq agent-shell-stats--codex-process proc)
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

(defun agent-shell-stats--agy-bucket-from-group (data id)
  "Return the usage bucket plist for bucket ID within agy JSON DATA's groups.
DATA is the `command.data' object from `agy --output-format json',
whose `groups' each contain one or more `buckets'.  ID is a bucket's
stable identifier (e.g. \"gemini-weekly\"), not its display name, since
agy's human-readable group/bucket names are free to change."
  (catch 'found
    (dolist (group (agent-shell-stats--jget data 'groups))
      (dolist (bucket (agent-shell-stats--jget group 'buckets))
        (when (equal (agent-shell-stats--jget bucket 'id) id)
          (throw 'found
                 (list :used (let ((frac (agent-shell-stats--jget bucket 'remaining_fraction)))
                               (and (numberp frac) (* 100 (- 1 frac))))
                       :reset (agent-shell-stats--iso-to-time
                               (agent-shell-stats--jget bucket 'reset_time)))))))))

(defun agent-shell-stats--agy-parse-result (parsed)
  "Convert agy's --output-format json PARSED payload into our display plist.
agy reports two weekly quota buckets shared across model families: one
for Gemini models, and one shared by Claude and GPT-OSS models."
  (let ((data (agent-shell-stats--jget (agent-shell-stats--jget parsed 'command) 'data)))
    (list :gemini (agent-shell-stats--agy-bucket-from-group data "gemini-weekly")
          :threep (agent-shell-stats--agy-bucket-from-group data "3p-weekly"))))

(defun agent-shell-stats--refresh-agy ()
  "Fetch Antigravity quota via `agy -p \"/quota\" --output-format json'."
  ;; Same race-avoidance rationale as `agent-shell-stats--refresh-codex':
  ;; kill a still-running previous refresh instead of letting two race.
  (when (process-live-p agent-shell-stats--agy-process)
    (agent-shell-stats--log "refresh-agy: killing still-live previous process")
    (delete-process agent-shell-stats--agy-process))
  (if-let ((exe (executable-find agent-shell-stats-agy-command)))
      (let* ((generation (setq agent-shell-stats--agy-generation
                                (1+ agent-shell-stats--agy-generation)))
             (buf (generate-new-buffer " *agent-shell-stats-agy*"))
             (proc
              (make-process
               :name "agent-shell-stats-agy"
               :buffer buf
               :command (list exe "-p" "/quota" "--output-format" "json")
               :coding 'utf-8-unix
               :connection-type 'pipe
               :noquery t
               :sentinel
               (lambda (p _event)
                 (when (memq (process-status p) '(exit signal))
                   (unwind-protect
                       (if (/= generation agent-shell-stats--agy-generation)
                           (agent-shell-stats--log
                            "agy gen=%d DISCARDED (current-gen=%d)"
                            generation agent-shell-stats--agy-generation)
                         (let ((output (with-current-buffer (process-buffer p) (buffer-string))))
                           (if (/= (process-exit-status p) 0)
                               (setq agent-shell-stats--agy-error (string-trim output))
                             (condition-case err
                                 (let* ((parsed (agent-shell-stats--parse-json output))
                                        (status (agent-shell-stats--jget parsed 'status)))
                                   (if (equal status "SUCCESS")
                                       (progn
                                         (setq agent-shell-stats--agy
                                               (agent-shell-stats--agy-parse-result parsed))
                                         (setq agent-shell-stats--agy-error nil))
                                     (setq agent-shell-stats--agy-error
                                           (format "quota fetch failed: %s" (or status output)))))
                               (error
                                (setq agent-shell-stats--agy-error
                                      (format "parse: %s" (error-message-string err))))))))
                     (when (buffer-live-p (process-buffer p))
                       (kill-buffer (process-buffer p)))
                     (force-mode-line-update t)))))))
        (setq agent-shell-stats--agy-process proc))
    (setq agent-shell-stats--agy-error
          (format "%s not found" agent-shell-stats-agy-command))))

;;;###autoload
(defun agent-shell-stats-refresh ()
  "Refresh Claude, Codex, and Antigravity subscription quotas asynchronously."
  (interactive)
  (setq agent-shell-stats--last-refresh (current-time))
  (agent-shell-stats--refresh-claude)
  (agent-shell-stats--refresh-codex)
  (agent-shell-stats--refresh-agy))

(defun agent-shell-stats--provider-tooltip (name data error)
  (cond
   (error (format "%s usage unavailable: %s\nShift-Mouse-1: refresh" name error))
   ((not data) (format "%s usage: waiting for first refresh\nShift-Mouse-1: refresh" name))
   (t
    (let ((plan (or (plist-get data :plan) "?")))
      (format "%s (%s)\nDisplay: %s percentage\nShift-Mouse-1: refresh; Mouse-1: details"
              name plan agent-shell-stats-display-as)))))

(defun agent-shell-stats--claude-string ()
  (if agent-shell-stats--claude
      (let ((s (agent-shell-stats--bucket-string
                "S" (plist-get agent-shell-stats--claude :session) 'short))
            (w (agent-shell-stats--bucket-string
                "W" (plist-get agent-shell-stats--claude :week) 'long)))
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
                           (list (and five (agent-shell-stats--bucket-string "5h" five 'short))
                                 (and week (agent-shell-stats--bucket-string "7d" week 'long))))
                     " ")
                  (string-join
                   (mapcar (lambda (x)
                             (agent-shell-stats--bucket-string (car x) (cdr x)))
                           windows)
                   " "))))
    (propertize "X ?" 'face 'shadow)))

(defun agent-shell-stats--agy-string ()
  (if agent-shell-stats--agy
      (let ((g (agent-shell-stats--bucket-string
                "G" (plist-get agent-shell-stats--agy :gemini) 'long))
            (p (agent-shell-stats--bucket-string
                "P" (plist-get agent-shell-stats--agy :threep) 'long)))
        (concat "A " g " " p))
    (propertize "A ?" 'face 'shadow)))

(defvar agent-shell-stats--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line S-mouse-1]
                (lambda (_event) (interactive "e") (agent-shell-stats-refresh)))
    (define-key map [mode-line mouse-1]
                (lambda (_event) (interactive "e") (agent-shell-stats-show-details)))
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
             'local-map agent-shell-stats--mode-line-map))
         (a (propertize
             (agent-shell-stats--agy-string)
             'help-echo (agent-shell-stats--provider-tooltip
                         "Antigravity" agent-shell-stats--agy agent-shell-stats--agy-error)
             'mouse-face 'mode-line-highlight
             'local-map agent-shell-stats--mode-line-map)))
    (concat " " c agent-shell-stats-separator x agent-shell-stats-separator a " ")))

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

(defun agent-shell-stats--detail-reset-string (reset &optional scale)
  "Return a human-readable description of when RESET occurs.
SCALE is passed through to `agent-shell-stats--time-left'."
  (if reset
      (format "resets %s (in %s)"
              (format-time-string "%Y-%m-%d %H:%M" reset)
              (or (agent-shell-stats--time-left reset scale) "now"))
    "no reset time reported"))

(defun agent-shell-stats--detail-bucket-line (label bucket &optional scale)
  "Return a human-readable line describing LABEL's usage BUCKET.
SCALE is passed through to `agent-shell-stats--time-left'."
  (concat (format "  %-16s" (concat label ":"))
          (if (not bucket)
              "unknown\n"
            (let ((used (plist-get bucket :used)))
              (concat
               (if (numberp used) (format "%3d%% used" (round used)) "unknown")
               ", "
               (if (and (numberp used) (= used 0))
                   "not used yet, no reset countdown"
                 (agent-shell-stats--detail-reset-string (plist-get bucket :reset) scale))
               "\n")))))

(defun agent-shell-stats--detail-window-label (key)
  "Expand a short Codex window KEY into a more readable label."
  (cond ((equal key "5h") "Session (5h)")
        ((equal key "7d") "Week (7d)")
        (t key)))

(defun agent-shell-stats--detail-window-scale (key)
  "Return the `agent-shell-stats--time-left' SCALE for Codex window KEY."
  (cond ((equal key "5h") 'short)
        ((equal key "7d") 'long)
        (t nil)))

(defun agent-shell-stats-show-details ()
  "Show the latest cached provider details in a human-readable format."
  (interactive)
  (with-help-window "*Agent usage*"
    (princ (format "Mode-line percentages show: %s\n\n" agent-shell-stats-display-as))
    (princ "Claude\n")
    (princ "------\n")
    (if agent-shell-stats--claude
        (progn
          (princ (format "  %-16s%s\n" "Plan:"
                         (or (plist-get agent-shell-stats--claude :plan) "?")))
          (princ (agent-shell-stats--detail-bucket-line
                  "Session" (plist-get agent-shell-stats--claude :session) 'short))
          (princ (agent-shell-stats--detail-bucket-line
                  "Week (all)" (plist-get agent-shell-stats--claude :week) 'long)))
      (princ (format "  unavailable%s\n"
                     (if agent-shell-stats--claude-error
                         (concat ": " agent-shell-stats--claude-error) ""))))
    (princ "\nCodex\n")
    (princ "-----\n")
    (if agent-shell-stats--codex
        (progn
          (princ (format "  %-16s%s\n" "Plan:"
                         (or (plist-get agent-shell-stats--codex :plan) "?")))
          (dolist (w (plist-get agent-shell-stats--codex :windows))
            (princ (agent-shell-stats--detail-bucket-line
                    (agent-shell-stats--detail-window-label (car w)) (cdr w)
                    (agent-shell-stats--detail-window-scale (car w))))))
      (princ (format "  unavailable%s\n"
                     (if agent-shell-stats--codex-error
                         (concat ": " agent-shell-stats--codex-error) ""))))
    (princ "\nAntigravity\n")
    (princ "-----------\n")
    (if agent-shell-stats--agy
        (progn
          (princ (agent-shell-stats--detail-bucket-line
                  "Gemini" (plist-get agent-shell-stats--agy :gemini) 'long))
          (princ (agent-shell-stats--detail-bucket-line
                  "Claude+GPT" (plist-get agent-shell-stats--agy :threep) 'long)))
      (princ (format "  unavailable%s\n"
                     (if agent-shell-stats--agy-error
                         (concat ": " agent-shell-stats--agy-error) ""))))
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
