package api

import (
	"context"
	"strings"
	"testing"
	"time"

	"prototip/internal/panel/store/storetest"
)

// The store's retried transactions are a counter of the scrape, not a number for tests.
func TestMetricsCountSerializationRetries(t *testing.T) {
	ctx := context.Background()
	st, err := storetest.Open(ctx, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	now := time.Unix(1_800_000_000, 0)
	h := &handlers{d: Deps{Store: st, Now: func() time.Time { return now }, Version: "test"}}
	body, err := h.renderMetrics(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	want := "# TYPE prototip_db_serialization_retries_total counter\nprototip_db_serialization_retries_total 0\n"
	if !strings.Contains(string(body), want) {
		t.Fatalf("no retries counter in:\n%s", body)
	}
}
