package shortcode

import "testing"

func TestNewLengthAndAlphabet(t *testing.T) {
	c, err := New(7)
	if err != nil {
		t.Fatal(err)
	}
	if len(c) != 7 {
		t.Fatalf("uzunluk 7 bekleniyordu, %d geldi", len(c))
	}
	if !Valid(c, 7) {
		t.Fatalf("üretilen kod kendi doğrulamasından geçmedi: %q", c)
	}
}

// 00'daki asıl hata buydu: kod uzayı küçük olunca çakışma rutinleşiyordu.
// 7 karakterde 20 bin üretimde tek çakışma bile beklenmez (62^7 ≈ 3.5e12).
func TestNoCollisionsAtScale(t *testing.T) {
	seen := make(map[string]struct{}, 20000)
	for i := 0; i < 20000; i++ {
		c, err := New(7)
		if err != nil {
			t.Fatal(err)
		}
		if _, dup := seen[c]; dup {
			t.Fatalf("20 bin üretimde çakışma çıktı: %q", c)
		}
		seen[c] = struct{}{}
	}
}

func TestValidRejectsForeignChars(t *testing.T) {
	for _, bad := range []string{"", "abc/def", "ab cd", "çğü", "toolongcode"} {
		if Valid(bad, 7) {
			t.Fatalf("geçersiz sayılmalıydı: %q", bad)
		}
	}
}
