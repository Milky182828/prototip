package mtproto

import (
	"encoding/hex"
	"strings"
	"testing"
)

func TestGenerateSecret(t *testing.T) {
	const domain = "www.cloudflare.com"
	secret, err := generateSecret(domain)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(secret, "ee") {
		t.Fatalf("secret has no fake TLS prefix: %q", secret)
	}
	raw, err := hex.DecodeString(strings.TrimPrefix(secret, "ee"))
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) != 16+len(domain) {
		t.Fatalf("secret has %d bytes, want %d", len(raw), 16+len(domain))
	}
	if got := string(raw[16:]); got != domain {
		t.Fatalf("secret domain = %q, want %q", got, domain)
	}
}

func TestValidDomain(t *testing.T) {
	if !validDomain("www.cloudflare.com") {
		t.Fatal("domain rejected")
	}
	for _, bad := range []string{"", "127.0.0.1", "::1", "not a domain"} {
		if validDomain(bad) {
			t.Fatalf("accepted %q", bad)
		}
	}
}
