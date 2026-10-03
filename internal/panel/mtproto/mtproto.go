package mtproto

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"prototip/internal/fsutil"
	"prototip/internal/hostname"
	"prototip/internal/panel/settings"
	"prototip/internal/panel/store"
	"prototip/internal/panel/store/db"
)

const (
	DefaultPort   = 8443
	DefaultDomain = "www.cloudflare.com"
)

type View struct {
	Enabled bool   `json:"enabled"`
	Port    int    `json:"port"`
	Domain  string `json:"domain"`
	Secret  string `json:"secret"`
	Link    string `json:"link"`
	Status  string `json:"status" enum:"stopped,starting,running,error"`
}

type Update struct {
	Enabled *bool
	Port    *int
	Domain  *string
}

type Manager struct {
	store   *store.Store
	set     *settings.Settings
	dataDir string
}

func New(st *store.Store, set *settings.Settings, dataDir string) *Manager {
	return &Manager{store: st, set: set, dataDir: dataDir}
}

func (m *Manager) View(ctx context.Context) (View, error) {
	var v View
	var err error
	if v.Enabled, _, err = settings.Get[bool](ctx, m.set, settings.KeyMTProtoEnabled); err != nil {
		return v, err
	}
	if v.Port, _, err = settings.Get[int](ctx, m.set, settings.KeyMTProtoPort); err != nil {
		return v, err
	}
	if v.Port == 0 {
		v.Port = DefaultPort
	}
	if v.Domain, _, err = settings.Get[string](ctx, m.set, settings.KeyMTProtoDomain); err != nil {
		return v, err
	}
	if v.Domain == "" {
		v.Domain = m.defaultDomain(ctx)
	}
	if v.Secret, _, err = settings.Get[string](ctx, m.set, settings.KeyMTProtoSecret); err != nil {
		return v, err
	}
	v.Status = m.status(v.Enabled)
	host, err := m.publicHost(ctx)
	if err != nil {
		return v, err
	}
	if v.Enabled && host != "" && v.Secret != "" {
		q := url.Values{"server": {host}, "port": {strconv.Itoa(v.Port)}, "secret": {v.Secret}}
		v.Link = "https://t.me/proxy?" + q.Encode()
	}
	return v, nil
}

func (m *Manager) Update(ctx context.Context, patch Update, regenerate bool) (View, error) {
	cur, err := m.View(ctx)
	if err != nil {
		return View{}, err
	}
	next := cur
	if patch.Enabled != nil {
		next.Enabled = *patch.Enabled
	}
	if patch.Port != nil {
		next.Port = *patch.Port
	}
	if patch.Domain != nil {
		next.Domain = strings.ToLower(strings.TrimSpace(*patch.Domain))
	}
	if next.Port < 1024 || next.Port > 65535 {
		return View{}, fmt.Errorf("mtproto_port_invalid")
	}
	if !validDomain(next.Domain) {
		return View{}, fmt.Errorf("mtproto_domain_invalid")
	}
	if regenerate || next.Secret == "" || next.Domain != cur.Domain {
		next.Secret, err = generateSecret(next.Domain)
		if err != nil {
			return View{}, err
		}
	}
	err = m.store.TxRC(ctx, func(q *db.Queries) error {
		set := settings.New(q)
		for key, value := range map[string]any{
			settings.KeyMTProtoEnabled: next.Enabled,
			settings.KeyMTProtoPort:    next.Port,
			settings.KeyMTProtoDomain:  next.Domain,
			settings.KeyMTProtoSecret:  next.Secret,
		} {
			switch v := value.(type) {
			case bool:
				if err := settings.Set(ctx, set, key, v); err != nil {
					return err
				}
			case int:
				if err := settings.Set(ctx, set, key, v); err != nil {
					return err
				}
			case string:
				if err := settings.Set(ctx, set, key, v); err != nil {
					return err
				}
			}
		}
		return nil
	})
	if err != nil {
		return View{}, err
	}
	if err := m.reconcile(ctx); err != nil {
		return View{}, err
	}
	return m.View(ctx)
}

func (m *Manager) Run(ctx context.Context) {
	_ = m.reconcile(ctx)
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			_ = m.reconcile(ctx)
		}
	}
}

func (m *Manager) reconcile(ctx context.Context) error {
	v, err := m.View(ctx)
	if err != nil {
		return err
	}
	dir := filepath.Join(m.dataDir, "mtproto")
	path := filepath.Join(dir, "config.toml")
	if !v.Enabled {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	if v.Secret == "" {
		return nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	body := fmt.Sprintf("secret = %q\nbind-to = %q\n", v.Secret, "0.0.0.0:"+strconv.Itoa(v.Port))
	return fsutil.WriteFileAtomic(path, []byte(body), 0o600)
}

func (m *Manager) status(enabled bool) string {
	if !enabled {
		return "stopped"
	}
	body, err := os.ReadFile(filepath.Join(m.dataDir, "mtproto", "status"))
	if err != nil {
		return "starting"
	}
	switch strings.TrimSpace(string(body)) {
	case "running":
		return "running"
	case "error":
		return "error"
	default:
		return "starting"
	}
}

func (m *Manager) defaultDomain(ctx context.Context) string {
	domain, _ := m.set.String(ctx, settings.KeyDomain)
	if validDomain(domain) {
		return domain
	}
	return DefaultDomain
}

func (m *Manager) publicHost(ctx context.Context) (string, error) {
	host, err := m.set.String(ctx, settings.KeyDomain)
	if err != nil {
		return "", err
	}
	if host == "" {
		host, err = m.set.String(ctx, settings.KeyPublicHost)
	}
	return host, err
}

func validDomain(s string) bool {
	return s != "" && net.ParseIP(s) == nil && hostname.Valid(s)
}

func generateSecret(domain string) (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return "ee" + hex.EncodeToString(raw) + hex.EncodeToString([]byte(domain)), nil
}
