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
;; SSH, so the login URL has to travel to the browser on the laptop. It is put
;; on the laptop's clipboard with OSC 52, the escape sequence that asks the
;; *terminal emulator* to set the system clipboard — which happens on the
;; laptop side of the SSH connection, where the browser is.
;;
;; Getting the sequence to the terminal takes one trick. A process spawned by
;; an agent tool has no controlling terminal, so /dev/tty fails with ENXIO. The
;; pty is still open further up the process tree, so the sequence is written
;; directly to that device instead.
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
    "  --no-clipboard      print the login URL only, do not touch the clipboard"
    "  -h, --help          this message"]))

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
        "--no-clipboard" (recur more (assoc opts :no-clipboard true))
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
;; Terminal
;;
;; /dev/tty is the obvious way to reach the terminal and it does not work here:
;; a process with no controlling terminal gets ENXIO on open, and a `-w
;; /dev/tty` test passes anyway because it only checks the device node's
;; permission bits. So walk up the process tree instead and take the pty from
;; the first ancestor that still has one.
;;
;; Two signals per process, because either alone has a blind spot. The fd links
;; are exact but miss a shell whose stdio is piped; tty_nr is the controlling
;; terminal, which such a shell still carries.

(defn- read-proc
  "Slurp fails on /proc with EINVAL under babashka — those files report a size
  of zero and want a single full read. Files/readAllBytes obliges."
  [& parts]
  (try
    (String. (java.nio.file.Files/readAllBytes (apply fs/path "/proc" parts)) "UTF-8")
    (catch Exception _ nil)))

(defn- ppid
  [pid]
  (some->> (read-proc (str pid) "status")
           str/split-lines
           (some #(second (re-matches #"PPid:\s+(\d+)" %)))
           parse-long))

(defn- fd-terminal
  "Terminal one of the process's standard fds is open on."
  [pid]
  (some (fn [fd]
          (try
            (let [link (fs/path "/proc" (str pid) "fd" (str fd))]
              (when (fs/exists? link {:nofollow-links true})
                (let [target (str (fs/read-link link))]
                  (when (re-matches #"/dev/(pts/\d+|tty\d+|console)" target) target))))
            (catch Exception _ nil)))
        [0 1 2]))

(defn- controlling-terminal
  "Device named by field 7 of /proc/<pid>/stat, decoded from its dev_t. Field
  counting starts after the comm field, which is parenthesised and may itself
  contain spaces and brackets."
  [pid]
  (when-let [stat (read-proc (str pid) "stat")]
    (let [after-comm (subs stat (inc (str/last-index-of stat ")")))
          tty-nr (some-> (str/split (str/trim after-comm) #"\s+") (nth 4 nil) parse-long)]
      (when (and tty-nr (pos? tty-nr))
        (let [major (bit-and (bit-shift-right tty-nr 8) 0xfff)
              minor (bit-or (bit-and tty-nr 0xff)
                            (bit-and (bit-shift-right tty-nr 12) 0xfff00))]
          (case major
            136 (str "/dev/pts/" minor)
            4 (str "/dev/tty" minor)
            nil))))))

(defn- terminal-device
  "Device path of the nearest terminal up the process tree, or nil if nothing
  in it owns one."
  []
  (loop [pid (.pid (java.lang.ProcessHandle/current)) depth 0]
    (when (and pid (pos? pid) (< depth 16))
      (or (fd-terminal pid)
          (controlling-terminal pid)
          (recur (ppid pid) (inc depth))))))

(defn- osc52
  "OSC 52 sequence setting the terminal's clipboard to text, wrapped for a
  multiplexer if one is in the way."
  [text]
  (let [payload (.encodeToString (java.util.Base64/getEncoder) (.getBytes text "UTF-8"))
        sequence (str "\u001b]52;c;" payload "\u0007")]
    (cond
      (System/getenv "TMUX") (str "\u001bPtmux;" (str/replace sequence "\u001b" "\u001b\u001b") "\u001b\\")
      (System/getenv "STY") (str "\u001bP" sequence "\u001b\\")
      :else sequence)))

(defn- copy!
  "Put text on the terminal's clipboard. Returns the device written to, or nil."
  [text device]
  (when device
    (try
      (with-open [out (java.io.FileOutputStream. (io/file device) true)]
        (.write out (.getBytes (osc52 text) "UTF-8"))
        (.flush out))
      device
      (catch Exception e
        (println (str "  could not write to " device ": " (.getMessage e)))
        nil))))

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
  it appears and putting it on the laptop's clipboard. The CLI prints that URL
  on a line of its own; nothing else it emits starts with http."
  [{:keys [profile region timeout no-clipboard]}]
  (when-not (port-free? 8181)
    (die 1 "Port 8181 is already in use, and the login flow needs it."
         "Another `oci session authenticate` may still be waiting — check with:"
         "    ss -lptn 'sport = :8181'"))
  (let [device (when-not no-clipboard (terminal-device))
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
                      (if (and (not @seen) (str/starts-with? text "http"))
                        (do
                          (reset! seen true)
                          (println)
                          (if-let [written (copy! text device)]
                            (println (str "Login URL copied to your clipboard via OSC 52 (" written ")."))
                            (println "Login URL (clipboard unavailable — copy it by hand):"))
                          (println)
                          (println text)
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
