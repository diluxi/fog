// invite: links that make an lldap account with the groups they were made
// for. an admin makes one at /new (behind authelia); whoever opens it picks
// a username, a contact address and a password, once, before it expires.
//
// a link is its own record: the groups, expiry and a nonce, signed with an
// hmac key that never leaves lemma0. the only state is the set of nonces
// already used.
package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"net/mail"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

type Group struct {
	Name  string `json:"name"`
	Label string `json:"label"`
	// what the new account can do with it, shown after signing up
	Info string `json:"info"`
}

type Config struct {
	Listen       string   `json:"listen"`
	URL          string   `json:"url"`
	LLDAPHTTP    string   `json:"lldapHttp"`
	LLDAPLDAP    string   `json:"lldapLdap"`
	BaseDN       string   `json:"baseDn"`
	User         string   `json:"user"`
	PasswordFile string   `json:"passwordFile"`
	KeyFile      string   `json:"keyFile"`
	StateDir     string   `json:"stateDir"`
	Ldappasswd   string   `json:"ldappasswd"`
	AdminGroup   string   `json:"adminGroup"`
	MailGroup    string   `json:"mailGroup"`
	MailDomain   string   `json:"mailDomain"`
	LocalDomains []string `json:"localDomains"`
	Reserved     []string `json:"reserved"`
	// accounts that aren't people: root and lldap's service accounts
	Services []string `json:"services"`
	Groups   []Group  `json:"groups"`
	// migrate: groups every person already here joins, once
	Existing []string `json:"existing"`
}

var (
	cfg     Config
	key     []byte
	pwFile  string
	nameRe  = regexp.MustCompile(`^[a-z][a-z0-9-]{0,30}[a-z0-9]$`)
	nonceRe = regexp.MustCompile(`^[0-9a-f]{32}$`)
)

func main() {
	config := flag.String("config", "", "json configuration")
	flag.Parse()
	raw, err := os.ReadFile(*config)
	if err != nil {
		log.Fatal(err)
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		log.Fatal(err)
	}
	if key, err = os.ReadFile(cfg.KeyFile); err != nil {
		log.Fatal(err)
	}
	pwFile = cfg.PasswordFile
	if err := os.MkdirAll(filepath.Join(cfg.StateDir, "used"), 0o700); err != nil {
		log.Fatal(err)
	}
	// once migrated, there's nothing to wait for lldap for
	if _, err := os.Stat(filepath.Join(cfg.StateDir, "migrated")); err == nil &&
		flag.Arg(0) == "migrate" {
		return
	}
	if err := ensureSchema(); err != nil {
		log.Fatal(err)
	}

	switch flag.Arg(0) {
	case "migrate":
		if err := migrate(); err != nil {
			log.Fatal(err)
		}
	case "serve", "":
		serve()
	default:
		log.Fatalf("unknown command %q", flag.Arg(0))
	}
}

// --- lldap ---------------------------------------------------------------

type gqlError struct{ Message string }

func gql(query string, vars any, out any) error {
	password, err := os.ReadFile(pwFile)
	if err != nil {
		return err
	}
	body, _ := json.Marshal(map[string]string{
		"username": cfg.User, "password": strings.TrimSpace(string(password)),
	})
	res, err := http.Post(cfg.LLDAPHTTP+"/auth/simple/login", "application/json",
		bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer res.Body.Close()
	var login struct{ Token string }
	if err := json.NewDecoder(res.Body).Decode(&login); err != nil || login.Token == "" {
		return fmt.Errorf("lldap login failed (%s)", res.Status)
	}

	body, _ = json.Marshal(map[string]any{"query": query, "variables": vars})
	req, _ := http.NewRequest("POST", cfg.LLDAPHTTP+"/api/graphql", bytes.NewReader(body))
	req.Header.Set("content-type", "application/json")
	req.Header.Set("authorization", "Bearer "+login.Token)
	res, err = http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	var r struct {
		Data   json.RawMessage
		Errors []gqlError
	}
	if err := json.NewDecoder(res.Body).Decode(&r); err != nil {
		return err
	}
	if len(r.Errors) > 0 {
		return errors.New(r.Errors[0].Message)
	}
	if out != nil {
		return json.Unmarshal(r.Data, out)
	}
	return nil
}

// the mailbox attribute: an account's address on this server, which
// stalwart reads. lldap's own mail is the person's contact address
func ensureSchema() error {
	var r struct {
		Schema struct {
			UserSchema struct {
				Attributes []struct{ Name string }
			}
		}
	}
	if err := gql(`{ schema { userSchema { attributes { name } } } }`, nil, &r); err != nil {
		return err
	}
	for _, a := range r.Schema.UserSchema.Attributes {
		if a.Name == "mailbox" {
			return nil
		}
	}
	log.Print("adding the mailbox attribute")
	return gql(`mutation { addUserAttribute(name: "mailbox", attributeType: STRING,
		isList: false, isVisible: true, isEditable: false) { ok } }`, nil, nil)
}

func groupIDs() (map[string]int, error) {
	var r struct {
		Groups []struct {
			ID          int
			DisplayName string
		}
	}
	if err := gql(`{ groups { id displayName } }`, nil, &r); err != nil {
		return nil, err
	}
	ids := map[string]int{}
	for _, g := range r.Groups {
		ids[g.DisplayName] = g.ID
	}
	return ids, nil
}

func addToGroups(user string, groups []string) error {
	ids, err := groupIDs()
	if err != nil {
		return err
	}
	for _, g := range groups {
		id, ok := ids[g]
		if !ok {
			return fmt.Errorf("no group %s", g)
		}
		if err := gql(`mutation($u: String!, $g: Int!) { addUserToGroup(userId: $u, groupId: $g) { ok } }`,
			map[string]any{"u": user, "g": id}, nil); err != nil {
			return err
		}
	}
	return nil
}

// ldap's password modify, since lldap only takes passwords that way or
// through its own opaque handshake. the password goes through a file
func setPassword(user, password string) error {
	f, err := os.CreateTemp("", "pw")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(password); err != nil {
		return err
	}
	f.Close()
	people := "ou=people," + cfg.BaseDN
	out, err := exec.Command(cfg.Ldappasswd, "-x", "-H", cfg.LLDAPLDAP,
		"-D", "uid="+cfg.User+","+people, "-y", pwFile,
		"-T", f.Name(), "uid="+user+","+people).CombinedOutput()
	if err != nil {
		return fmt.Errorf("ldappasswd: %v: %s", err, out)
	}
	return nil
}

// --- links ---------------------------------------------------------------

type Invite struct {
	Groups  []string `json:"g"`
	Expires int64    `json:"e"`
	Nonce   string   `json:"n"`
	By      string   `json:"b"`
}

func sign(payload []byte) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte("invite\n"))
	m.Write(payload)
	return m.Sum(nil)
}

func encode(inv Invite) string {
	payload, _ := json.Marshal(inv)
	b := base64.RawURLEncoding
	return b.EncodeToString(payload) + "." + b.EncodeToString(sign(payload))
}

var errExpired = errors.New("this invitation has expired")
var errUsed = errors.New("this invitation has already been used")

func decode(token string) (Invite, error) {
	var inv Invite
	b := base64.RawURLEncoding
	p, s, ok := strings.Cut(token, ".")
	payload, err1 := b.DecodeString(p)
	mac, err2 := b.DecodeString(s)
	if !ok || err1 != nil || err2 != nil || !hmac.Equal(mac, sign(payload)) {
		return inv, errors.New("this isn't a valid invitation")
	}
	if err := json.Unmarshal(payload, &inv); err != nil || !nonceRe.MatchString(inv.Nonce) {
		return inv, errors.New("this isn't a valid invitation")
	}
	if time.Now().Unix() > inv.Expires {
		return inv, errExpired
	}
	if _, err := os.Stat(usedPath(inv)); err == nil {
		return inv, errUsed
	}
	// only groups still offered, even from a valid link
	for _, g := range inv.Groups {
		if findGroup(g) == nil {
			return inv, fmt.Errorf("this invitation offers %s, which is no longer offered", g)
		}
	}
	return inv, nil
}

func usedPath(inv Invite) string { return filepath.Join(cfg.StateDir, "used", inv.Nonce) }

// claiming creates the marker exclusively, so two people can't redeem one
// link at the same time
func claim(inv Invite) error {
	f, err := os.OpenFile(usedPath(inv), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return errUsed
	}
	return f.Close()
}

func findGroup(name string) *Group {
	for i := range cfg.Groups {
		if cfg.Groups[i].Name == name {
			return &cfg.Groups[i]
		}
	}
	return nil
}

// --- web -----------------------------------------------------------------

var page = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{.Title}}</title>
<style>
:root { color-scheme: light dark; --fg: #1d1d1f; --bg: #fbfbfa; --muted: #6b6b70; --line: #d9d9de; --accent: #3a5bc7; --bad: #b3261e; }
@media (prefers-color-scheme: dark) { :root { --fg: #e8e8ea; --bg: #141416; --muted: #9a9aa2; --line: #333338; --accent: #8fa8ff; --bad: #ff8a80; } }
body { font: 16px/1.5 system-ui, sans-serif; color: var(--fg); background: var(--bg); margin: 0; padding: 2rem 1rem; }
main { max-width: 26rem; margin: 0 auto; }
h1 { font-size: 1.4rem; margin: 0 0 1rem; }
label { display: block; margin: 1rem 0 .25rem; font-weight: 600; }
input[type=text], input[type=email], input[type=password], select { width: 100%; box-sizing: border-box; padding: .55rem .6rem; font: inherit; color: inherit; background: transparent; border: 1px solid var(--line); border-radius: 6px; }
.check { display: flex; gap: .5rem; align-items: baseline; font-weight: 400; margin: .4rem 0; }
button { margin-top: 1.5rem; padding: .6rem 1.2rem; font: inherit; color: var(--bg); background: var(--accent); border: 0; border-radius: 6px; cursor: pointer; }
.hint { color: var(--muted); font-size: .9rem; }
.error { color: var(--bad); }
code, .link { word-break: break-all; font-family: ui-monospace, monospace; font-size: .9rem; }
.link { padding: .6rem; border: 1px solid var(--line); border-radius: 6px; user-select: all; }
ul { padding-left: 1.2rem; }
</style></head><body><main>
<h1>{{.Title}}</h1>
{{if .Error}}<p class="error">{{.Error}}</p>{{end}}
{{if eq .Kind "new"}}
<form method="post">
<label>Groups</label>
{{range .Groups}}<label class="check"><input type="checkbox" name="group" value="{{.Name}}"> {{.Label}}</label>{{end}}
<label for="days">Valid for</label>
<select id="days" name="days">
<option value="1">1 day</option><option value="3">3 days</option>
<option value="7" selected>7 days</option><option value="14">14 days</option>
<option value="30">30 days</option></select>
<button>Make link</button>
</form>
{{else if eq .Kind "link"}}
<p>Send this to the person you're inviting. It works once, until {{.Expires}}.</p>
<p class="link">{{.Link}}</p>
<p class="hint">It gives: {{range $i, $g := .Offered}}{{if $i}}, {{end}}{{$g.Label}}{{end}}.</p>
<p><a href="/new">Make another</a></p>
{{else if eq .Kind "join"}}
<p>You've been invited to amartia.online, with access to:</p>
<ul>{{range .Offered}}<li>{{.Label}}</li>{{end}}</ul>
<form method="post">
<label for="username">Username</label>
<input id="username" name="username" type="text" value="{{.Username}}" required
 pattern="[a-z][a-z0-9\-]{0,30}[a-z0-9]" autocapitalize="none" autocomplete="username">
<p class="hint">Lowercase letters, digits and dashes.{{if .MailDomain}} Your address here will be <i>username</i>@{{.MailDomain}}.{{end}}</p>
<label for="email">Email</label>
<input id="email" name="email" type="email" value="{{.Email}}" required autocomplete="email">
<p class="hint">An address you already have, for resetting your password.</p>
<label for="password">Password</label>
<input id="password" name="password" type="password" minlength="12" required autocomplete="new-password">
<label for="again">Password, again</label>
<input id="again" name="again" type="password" minlength="12" required autocomplete="new-password">
<p class="hint">At least 12 characters.</p>
<button>Create account</button>
</form>
{{else if eq .Kind "done"}}
<p>Welcome, {{.Username}}. You log in everywhere with that username and your password.</p>
<ul>{{range .Offered}}<li><b>{{.Label}}</b>: {{.Info}}</li>{{end}}</ul>
{{end}}
</main></body></html>`))

type view struct {
	Title, Kind, Error, Link, Expires, Username, Email, MailDomain string
	Groups, Offered                                                []Group
}

func render(w http.ResponseWriter, status int, v view) {
	w.Header().Set("content-type", "text/html; charset=utf-8")
	w.Header().Set("cache-control", "no-store")
	w.Header().Set("referrer-policy", "no-referrer")
	w.Header().Set("x-frame-options", "DENY")
	w.WriteHeader(status)
	if err := page.Execute(w, v); err != nil {
		log.Print(err)
	}
}

func offered(names []string) []Group {
	var gs []Group
	for _, n := range names {
		if g := findGroup(n); g != nil {
			gs = append(gs, *g)
		}
	}
	return gs
}

// /new is reached only through authelia's forward auth, which sets these.
// they are checked again here in case caddy is ever misconfigured
func admin(r *http.Request) (string, bool) {
	user := r.Header.Get("Remote-User")
	groups := strings.Split(r.Header.Get("Remote-Groups"), ",")
	return user, user != "" && slices.Contains(groups, cfg.AdminGroup)
}

func newForm(w http.ResponseWriter, r *http.Request) {
	if _, ok := admin(r); !ok {
		render(w, 403, view{Title: "Not allowed", Error: "Only admins make invitations."})
		return
	}
	render(w, 200, view{Title: "New invitation", Kind: "new", Groups: cfg.Groups})
}

func newLink(w http.ResponseWriter, r *http.Request) {
	user, ok := admin(r)
	if !ok {
		render(w, 403, view{Title: "Not allowed", Error: "Only admins make invitations."})
		return
	}
	r.ParseForm()
	again := view{Title: "New invitation", Kind: "new", Groups: cfg.Groups}
	groups := r.Form["group"]
	for _, g := range groups {
		if findGroup(g) == nil {
			again.Error = "Unknown group " + g + "."
			render(w, 400, again)
			return
		}
	}
	if len(groups) == 0 {
		again.Error = "Pick at least one group."
		render(w, 400, again)
		return
	}
	days, err := strconv.Atoi(r.FormValue("days"))
	if err != nil || days < 1 || days > 30 {
		again.Error = "Between 1 and 30 days."
		render(w, 400, again)
		return
	}
	nonce := make([]byte, 16)
	rand.Read(nonce)
	expires := time.Now().Add(time.Duration(days) * 24 * time.Hour)
	inv := Invite{Groups: groups, Expires: expires.Unix(), Nonce: hex.EncodeToString(nonce), By: user}
	log.Printf("%s made an invitation for %v, until %s", user, groups, expires.Format(time.RFC3339))
	render(w, 200, view{Title: "Invitation", Kind: "link",
		Link: cfg.URL + "/join/" + encode(inv), Expires: expires.UTC().Format("2 Jan 2006 15:04 UTC"),
		Offered: offered(groups)})
}

func joinView(inv Invite) view {
	v := view{Title: "Join amartia.online", Kind: "join", Offered: offered(inv.Groups)}
	if slices.Contains(inv.Groups, cfg.MailGroup) {
		v.MailDomain = cfg.MailDomain
	}
	return v
}

func joinForm(w http.ResponseWriter, r *http.Request) {
	inv, err := decode(r.PathValue("token"))
	if err != nil {
		render(w, 410, view{Title: "Invitation", Error: err.Error()})
		return
	}
	render(w, 200, joinView(inv))
}

func join(w http.ResponseWriter, r *http.Request) {
	inv, err := decode(r.PathValue("token"))
	if err != nil {
		render(w, 410, view{Title: "Invitation", Error: err.Error()})
		return
	}
	r.ParseForm()
	v := joinView(inv)
	v.Username = strings.TrimSpace(r.FormValue("username"))
	v.Email = strings.TrimSpace(r.FormValue("email"))
	fail := func(status int, msg string) {
		v.Error = msg
		render(w, status, v)
	}

	user, email, password := v.Username, v.Email, r.FormValue("password")
	switch {
	case !nameRe.MatchString(user):
		fail(400, "Usernames are 2 to 32 lowercase letters, digits and dashes, starting with a letter.")
		return
	case slices.Contains(cfg.Reserved, user):
		fail(409, "That username is taken.")
		return
	}
	addr, err := mail.ParseAddress(email)
	if err != nil || addr.Address != email || len(email) > 254 {
		fail(400, "That doesn't look like an email address.")
		return
	}
	domain := strings.ToLower(email[strings.LastIndex(email, "@")+1:])
	if slices.Contains(cfg.LocalDomains, domain) {
		fail(400, "Use an address you have elsewhere; it's how you reset your password.")
		return
	}
	switch {
	case len(password) < 12:
		fail(400, "Passwords need at least 12 characters.")
		return
	case len(password) > 256:
		fail(400, "That password is too long.")
		return
	case password != r.FormValue("again"):
		fail(400, "The passwords don't match.")
		return
	}

	// is the name or address in use? lldap would refuse either anyway, but
	// this way the link isn't spent on a mistake
	var existing struct{ Users []struct{ ID string } }
	if err := gql(`query($u: String!, $m: String!) { users(filters: { any: [
		{ eq: { field: "user_id", value: $u } }, { eq: { field: "mail", value: $m } } ] }) { id } }`,
		map[string]any{"u": user, "m": email}, &existing); err != nil {
		log.Print(err)
		fail(500, "Something went wrong on our side. Try again later.")
		return
	}
	if len(existing.Users) > 0 {
		fail(409, "That username or email address is already in use.")
		return
	}

	if err := claim(inv); err != nil {
		render(w, 410, view{Title: "Invitation", Error: err.Error()})
		return
	}
	if err := provision(inv, user, email, password); err != nil {
		log.Printf("provisioning %s failed: %v", user, err)
		os.Remove(usedPath(inv))
		fail(500, "Something went wrong on our side, and nothing was created. Try again later.")
		return
	}
	log.Printf("%s joined through %s's invitation, with %v", user, inv.By, inv.Groups)
	render(w, 200, view{Title: "Welcome", Kind: "done", Username: user, Offered: offered(inv.Groups)})
}

// create, add to groups, set the password; undone as a whole on failure
func provision(inv Invite, user, email, password string) error {
	attrs := []map[string]any{}
	if slices.Contains(inv.Groups, cfg.MailGroup) {
		attrs = append(attrs, map[string]any{
			"name": "mailbox", "value": []string{user + "@" + cfg.MailDomain}})
	}
	if err := gql(`mutation($u: CreateUserInput!) { createUser(user: $u) { id } }`,
		map[string]any{"u": map[string]any{
			"id": user, "email": email, "displayName": user, "attributes": attrs,
		}}, nil); err != nil {
		return err
	}
	err := addToGroups(user, inv.Groups)
	if err == nil {
		err = setPassword(user, password)
	}
	if err != nil {
		if derr := gql(`mutation($u: String!) { deleteUser(userId: $u) { ok } }`,
			map[string]any{"u": user}, nil); derr != nil {
			log.Printf("and removing %s again failed: %v", user, derr)
		}
	}
	return err
}

func serve() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /new", newForm)
	mux.HandleFunc("POST /new", newLink)
	mux.HandleFunc("GET /join/{token}", joinForm)
	mux.HandleFunc("POST /join/{token}", join)
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		render(w, 200, view{Title: "Invitations", Error: "You need an invitation link to join."})
	})
	srv := &http.Server{Addr: cfg.Listen, Handler: mux,
		ReadTimeout: 10 * time.Second, WriteTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10}
	log.Printf("listening on %s", cfg.Listen)
	log.Fatal(srv.ListenAndServe())
}

// --- the change to groups ------------------------------------------------

// before invitations, every person here had mail and xmpp. those are
// groups now, so everyone already here joins them once, and people whose
// lldap address is local get it as their mailbox
func migrate() error {
	stamp := filepath.Join(cfg.StateDir, "migrated")
	var r struct {
		Users []struct {
			ID, Email  string
			Attributes []struct {
				Name  string
				Value []string
			}
			Groups []struct{ DisplayName string }
		}
	}
	if err := gql(`{ users { id email attributes { name value } groups { displayName } } }`,
		nil, &r); err != nil {
		return err
	}
	for _, u := range r.Users {
		var groups []string
		for _, g := range u.Groups {
			groups = append(groups, g.DisplayName)
		}
		if slices.Contains(cfg.Services, u.ID) {
			continue
		}
		var join []string
		for _, g := range cfg.Existing {
			if !slices.Contains(groups, g) {
				join = append(join, g)
			}
		}
		at := strings.LastIndex(u.Email, "@")
		local := at > 0 && slices.Contains(cfg.LocalDomains, strings.ToLower(u.Email[at+1:]))
		hasMailbox := slices.ContainsFunc(u.Attributes, func(a struct {
			Name  string
			Value []string
		}) bool {
			return a.Name == "mailbox"
		})
		if local && !hasMailbox {
			log.Printf("%s's mailbox is %s", u.ID, u.Email)
			if err := gql(`mutation($u: UpdateUserInput!) { updateUser(user: $u) { ok } }`,
				map[string]any{"u": map[string]any{"id": u.ID, "insertAttributes": []map[string]any{
					{"name": "mailbox", "value": []string{u.Email}}}}}, nil); err != nil {
				return err
			}
		}
		if local && !slices.Contains(groups, cfg.MailGroup) {
			join = append(join, cfg.MailGroup)
		}
		if len(join) > 0 {
			log.Printf("%s joins %v", u.ID, join)
			if err := addToGroups(u.ID, join); err != nil {
				return err
			}
		}
	}
	return os.WriteFile(stamp, nil, 0o600)
}
