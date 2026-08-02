#!/usr/bin/env bb
;; Refresh the OCI CLI session token.
;;
;; The local OCI profile is session-token based — a consuming project's .envrc
;; sets OCI_CLI_AUTH=security_token because the `oci` CLI rejects that profile
;; otherwise — and Oracle caps a session at 60 minutes. A stale token surfaces
;; as an auth failure at plan time, not as a config error, so a `create` gets
;; most of the way in before it fails. This is the shortest path back.
;;
;; Two cases, and only the first is quick:
;;
;;   token still valid   `oci session refresh` extends it in place. No browser,
;;                       no interaction. Worth doing before a long create.
;;   token expired       past the refresh window only `oci session authenticate`
;;                       helps, and that is a browser login flow.
;;
;; `--no-browser` is not a way out of the browser: it calls
;; generate_user_security_token with whatever credentials the profile already
;; has, which on an expired session are the expired ones.
;;
;; This machine is headless (no DISPLAY, no browser on PATH) and reached over
;; SSH, so the login URL has to travel to the browser on the laptop. `$EDITOR`
;; names the current Emacs server; the script asks its `emacsclient` to evaluate
;; `kill-new`, and that Emacs carries the URL to the laptop's clipboard.
;;
;; The clipboard is the *only* channel. The URL is never printed, on any path
;; and under any flag. Before the OCI CLI is spawned, the script requires an
;; `emacsclient -s <server>` (or `--socket-name`) command in `$EDITOR` and proves
;; that the server answers. If the later `kill-new` call fails, the login process
;; is cancelled rather than falling back to the screen.
;;
;; One thing this cannot do for you: `oci session authenticate` serves the OAuth
;; redirect on http://localhost:8181, and "localhost" is resolved by the browser
;; — on the laptop. That port must reach this host or the login completes in the
;; browser and never comes back:
;;
;;     ssh -L 8181:localhost:8181 <this-host>

(require '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[cheshire.core :as json]
         '[clojure.java.io :as io]
         '[clojure.string :as str])

(def ^:private usage
  (str/join
   \newline
   ["Usage: refresh-oci-token.clj [options]"
    ""
    "  --profile NAME      OCI config profile (default: $OCI_CLI_PROFILE or DEFAULT)"
    "  --region ID         region for the login flow (default: the profile's region)"
    "  --force             skip the refresh path and re-authenticate outright"
    "  --timeout SECONDS   how long to wait for the browser redirect (default: 300)"
    "  -h, --help          this message"
    ""
    "The login URL is added to the current Emacs kill ring, never printed."]))

(defn- die
  [code & lines]
  (binding [*out* *err*] (run! println lines))
  (System/exit code))

(defn- parse-args
  [args]
  (loop [[arg & more] args opts {:timeout 300}]
    (if-not arg
      opts
      (case arg
        ("-h" "--help") (assoc opts :help true)
        "--profile" (recur (rest more) (assoc opts :profile (first more)))
        "--region" (recur (rest more) (assoc opts :region (first more)))
        "--timeout" (recur (rest more) (assoc opts :timeout (parse-long (str (first more)))))
        "--force" (recur more (assoc opts :force true))
        (die 2 (str "unknown argument: " arg) usage)))))

;; ---------------------------------------------------------------------------
;; OCI config

(def ^:private config-file (fs/file (fs/home) ".oci" "config"))

(defn- read-config
  "Parse ~/.oci/config into {profile {key value}}. Only enough INI to find the
  region; the CLI itself is the authority on everything else."
  []
  (when-not (fs/exists? config-file)
    (die 2 (str "no OCI config at " config-file)))
  (->> (str/split-lines (slurp config-file))
       (map str/trim)
       (remove #(or (str/blank? %) (str/starts-with? % "#")))
       (reduce (fn [{:keys [section] :as acc} line]
                 (if-let [[_ name*] (re-matches #"\[(.+)\]" line)]
                   (assoc acc :section name*)
                   (let [[k v] (str/split line #"=" 2)]
                     (cond-> acc
                       (and section v) (assoc-in [:profiles section (str/trim k)] (str/trim v))))))
               {})
       :profiles))

(defn- token-file
  [profile]
  (fs/file (fs/home) ".oci" "sessions" profile "token"))

(defn- token-expiry
  "Expiry Instant read out of the session token's JWT, or nil."
  [profile]
  (let [f (token-file profile)]
    (when (fs/exists? f)
      (try
        (let [payload (second (str/split (str/trim (slurp f)) #"\."))
              claims (-> (java.util.Base64/getUrlDecoder)
                         (.decode payload)
                         (String. "UTF-8")
                         (json/parse-string true))]
          (some-> (:exp claims) long java.time.Instant/ofEpochSecond))
        (catch Exception _ nil)))))

(defn- human-time
  [^java.time.Instant instant]
  (.format (.atZone instant (java.time.ZoneId/systemDefault))
           (java.time.format.DateTimeFormatter/ofPattern "yyyy-MM-dd HH:mm:ss z")))

;; ---------------------------------------------------------------------------
;; Emacs
;;
;; Neoemacs puts its per-process server in $EDITOR as `emacsclient -s <name>`.
;; Use that exact command rather than the default server: more than one Emacs
;; may be running, and only the current one owns this shell's clipboard path.

(defn- socket-name
  [argv]
  (loop [[arg & more] argv]
    (cond
      (nil? arg) nil
      (#{"-s" "--socket-name"} arg) (first more)
      (str/starts-with? arg "--socket-name=") (subs arg (count "--socket-name="))
      :else (recur more))))

(defn- emacs-eval
  [{:keys [argv]} expression]
  @(p/process (into argv ["--quiet" "--suppress-output" "--eval" expression])
              {:in "" :out :string :err :string}))

(defn- emacs-client!
  "Parse $EDITOR, require its named Emacs server to answer, and return the
  command to use. This runs before OCI starts so a missing clipboard channel
  cannot leave an authentication process waiting on an undisclosed URL."
  []
  (let [editor (System/getenv "EDITOR")]
    (when (str/blank? editor)
      (die 1 "$EDITOR is not set, so there is no current Emacs server for the login URL."))
    (let [argv (try
                 (p/tokenize editor)
                 (catch Exception _
                   (die 1 "$EDITOR could not be parsed as a command.")))
          server (socket-name argv)
          program (first argv)]
      (when-not (and program (= "emacsclient" (fs/file-name program)))
        (die 1 "$EDITOR must invoke emacsclient."
             (str "Found: " editor)))
      (when (str/blank? server)
        (die 1 "$EDITOR must name the current Emacs server with -s or --socket-name."
             (str "Found: " editor)))
      (when-not (fs/which program)
        (die 1 (str "The emacsclient named by $EDITOR is not on PATH: " program)))
      (let [client {:argv argv :server server}
            {:keys [exit]} (emacs-eval client "t")]
        (when-not (zero? exit)
          (die 1 (str "The Emacs server named by $EDITOR is not available: " server)))
        client))))

(defn- yank!
  "Add text to the current Emacs kill ring without placing the text itself in
  emacsclient's result. Base64 keeps URL punctuation out of the Elisp source."
  [client text]
  (let [payload (.encodeToString (java.util.Base64/getEncoder) (.getBytes text "UTF-8"))
        expression (str "(progn (kill-new (decode-coding-string "
                        "(base64-decode-string " (pr-str payload) ") 'utf-8)) t)")]
    (zero? (:exit (emacs-eval client expression)))))

;; ---------------------------------------------------------------------------
;; The oci CLI
;;
;; Every invocation gets an empty stdin. `oci session validate` without --local
;; asks "Do you want to re-authenticate?" when it fails, and a prompt with no
;; reader behind it is a hang.

(def ^:private ansi
  ;; The CLI paints a progress screen — alternate buffer, colours and all —
  ;; even when its output is a pipe. Echoing that raw corrupts the display.
  #"\u001b\[[0-9;?]*[ -/]*[@-~]|\u001b\][^\u0007]*\u0007|\u001b[()][0-9A-B]|\u001b[=>@-Z\\-_]")

(defn- strip-ansi
  [s]
  (-> s
      (str/replace ansi "")
      (str/replace #"[\p{Cntrl}&&[^\t]]" "")))

(defn- oci
  [& args]
  @(p/process (into ["oci"] args) {:in "" :out :string :err :string}))

(defn- session-valid?
  "Locally check the token's expiry. --local keeps this offline and, more to the
  point, keeps it from prompting."
  [profile]
  (zero? (:exit (oci "session" "validate" "--profile" profile "--local"))))

(defn- refresh!
  [profile]
  (let [{:keys [exit out err]} (oci "session" "refresh" "--profile" profile)]
    (when-not (zero? exit)
      (println (str "  " (str/trim (str out err)))))
    (zero? exit)))

(defn- port-free?
  [port]
  (try
    (with-open [socket (java.net.ServerSocket.)]
      (.bind socket (java.net.InetSocketAddress. port))
      true)
    (catch java.io.IOException _ false)))

(defn- authenticate!
  "Drive the browser login flow, lifting the URL out of the CLI's own output as
  it appears and adding it to the current Emacs kill ring. The CLI prints that
  URL on a line of its own; nothing else it emits starts with http."
  [{:keys [profile region timeout]}]
  (when-not (port-free? 8181)
    (die 1 "Port 8181 is already in use, and the login flow needs it."
         "Another `oci session authenticate` may still be waiting — check with:"
         "    ss -lptn 'sport = :8181'"))
  (let [client (emacs-client!)
        proc (p/process ["oci" "session" "authenticate"
                         "--region" region
                         "--profile-name" profile]
                        {:in "" :out :stream :err :stream})
        seen (atom false)
        drain (fn [stream]
                (future
                  (with-open [reader (io/reader stream)]
                    (doseq [line (line-seq reader)
                            :let [text (str/trim (strip-ansi line))]]
                      (if (and (str/starts-with? text "http")
                               (compare-and-set! seen false true))
                        (do
                          (when-not (yank! client text)
                            ;; Nothing left to try — the URL is never printed,
                            ;; so cancel rather than wait on a login no one can
                            ;; start.
                            (p/destroy-tree proc)
                            (die 1 ""
                                 "Emacs could not add the login URL to its kill ring, and it is"
                                 "never printed. This login attempt has been cancelled."))
                          (println)
                          (println (str "Login URL added to the kill ring of Emacs server "
                                        (:server client) "."))
                          (println "It is not printed here — the clipboard is the only channel.")
                          (println)
                          (println "Paste it into a browser on your laptop and complete the login.")
                          (println "The redirect lands on http://localhost:8181, which resolves on the")
                          (println "laptop — that port must be forwarded to this host:")
                          (println)
                          (println "    ssh -L 8181:localhost:8181 <this-host>")
                          (println)
                          (println (format "Waiting up to %ds for the redirect..." timeout)))
                        (when (seq text) (println (str "  " text))))))))
        pumps [(drain (:out proc)) (drain (:err proc))]
        result (deref (future @proc) (* 1000 timeout) ::timeout)]
    (when (= result ::timeout)
      (p/destroy-tree proc)
      (die 1 ""
           "Timed out waiting for the browser redirect."
           ""
           "The login most likely succeeded in the browser and the redirect never"
           "reached this host. Check that the SSH forward is in place:"
           ""
           "    ssh -L 8181:localhost:8181 <this-host>"
           ""
           "Without it the browser tab ends on a connection error after login."))
    (run! deref pumps)
    (zero? (:exit result))))

;; ---------------------------------------------------------------------------

(defn- report!
  [profile]
  (if-let [expiry (token-expiry profile)]
    (let [minutes (.toMinutes (java.time.Duration/between (java.time.Instant/now) expiry))]
      (println (format "Profile %s is good until %s (%d minutes)."
                       profile (human-time expiry) minutes)))
    (println (format "Profile %s refreshed." profile))))

(defn- main
  [args]
  (let [{:keys [help profile region force] :as opts} (parse-args args)]
    (when help (println usage) (System/exit 0))
    (when-not (fs/which "oci")
      (die 2 "`oci` is not on PATH — run inside `devenv shell`, or `direnv allow` first."))
    (let [profiles (read-config)
          profile (or profile (System/getenv "OCI_CLI_PROFILE") "DEFAULT")
          _ (when-not (contains? profiles profile)
              (die 2 (format "profile %s is not in %s (found: %s)"
                             profile config-file (str/join ", " (sort (keys profiles))))))
          region (or region
                     (get-in profiles [profile "region"])
                     (die 2 (format "no region for profile %s — pass --region" profile)))
          opts (assoc opts :profile profile :region region)]
      (println (format "Profile %s, region %s." profile region))
      (if (and (not force) (session-valid? profile))
        (do
          (println "Session is still valid — extending it in place, no browser needed.")
          (if (refresh! profile)
            (report! profile)
            (do (println "Refresh was rejected; falling back to a full login.")
                (if (authenticate! opts) (report! profile) (System/exit 1)))))
        (do
          (println (if force
                     "Re-authenticating on request."
                     "Session is expired or missing — a browser login is the only way back."))
          (if (authenticate! opts) (report! profile) (System/exit 1)))))))

;; Only when run as a script, so the file can be loaded and its pieces
;; exercised without starting a login flow.
(when (= *file* (System/getProperty "babashka.file"))
  (main *command-line-args*))
