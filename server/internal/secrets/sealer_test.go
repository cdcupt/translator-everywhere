package secrets

import (
	"bytes"
	"encoding/base64"
	"testing"
)

// keyN returns a deterministic valid base64-encoded 32-byte master key. Each
// distinct b yields a distinct key so tests can model "wrong master key".
func keyN(b byte) string {
	return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{b}, masterKeyLen))
}

func mustSealer(t *testing.T, base64Key string) *Sealer {
	t.Helper()
	s, err := NewSealer(base64Key)
	if err != nil {
		t.Fatalf("NewSealer: %v", err)
	}
	return s
}

func TestSealOpenRoundTrip(t *testing.T) {
	s := mustSealer(t, keyN(0x11))
	plaintext := []byte("sk-round-trip-secret")
	aad := []byte("user-a|openai-key")

	blob, err := s.Seal(plaintext, aad)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if blob[0] != currentKeyID {
		t.Errorf("blob[0] = 0x%02x, want key_id 0x%02x", blob[0], currentKeyID)
	}
	if bytes.Contains(blob, plaintext) {
		t.Fatal("ciphertext contains the plaintext — not encrypted")
	}

	got, err := s.Open(blob, aad)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if !bytes.Equal(got, plaintext) {
		t.Errorf("round-trip = %q, want %q", got, plaintext)
	}
}

func TestSealUsesFreshNonce(t *testing.T) {
	s := mustSealer(t, keyN(0x22))
	plaintext := []byte("same-input")
	aad := []byte("aad")

	a, err := s.Seal(plaintext, aad)
	if err != nil {
		t.Fatalf("Seal a: %v", err)
	}
	b, err := s.Seal(plaintext, aad)
	if err != nil {
		t.Fatalf("Seal b: %v", err)
	}
	if bytes.Equal(a, b) {
		t.Fatal("two seals of the same input are identical — nonce was reused")
	}
	// The 12-byte nonce region (after the key_id byte) must differ.
	if bytes.Equal(a[1:1+nonceLen], b[1:1+nonceLen]) {
		t.Fatal("nonce did not change between seals")
	}
}

func TestOpenWithWrongMasterKeyFailsClosed(t *testing.T) {
	sealer := mustSealer(t, keyN(0x33))
	attacker := mustSealer(t, keyN(0x44)) // different 32-byte key, same key_id 0x01
	plaintext := []byte("sk-should-stay-secret")
	aad := []byte("user|openai-key")

	blob, err := sealer.Seal(plaintext, aad)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	got, err := attacker.Open(blob, aad)
	if err == nil {
		t.Fatal("Open with wrong master key succeeded — must fail closed")
	}
	if got != nil {
		t.Fatalf("Open returned plaintext %q on failure — must be nil", got)
	}
}

func TestOpenRejectsTampering(t *testing.T) {
	s := mustSealer(t, keyN(0x55))
	plaintext := []byte("tamper-target")
	aad := []byte("aad")

	blob, err := s.Seal(plaintext, aad)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	// Flip a byte in each region: nonce, ciphertext, and the trailing GCM tag.
	regions := map[string]int{
		"nonce":      1,             // first nonce byte
		"ciphertext": 1 + nonceLen,  // first ciphertext byte
		"tag":        len(blob) - 1, // last tag byte
	}
	for name, idx := range regions {
		tampered := append([]byte(nil), blob...)
		tampered[idx] ^= 0xff
		got, err := s.Open(tampered, aad)
		if err == nil {
			t.Errorf("%s tamper: Open succeeded — GCM must reject", name)
		}
		if got != nil {
			t.Errorf("%s tamper: Open returned plaintext — must be nil", name)
		}
	}
}

func TestOpenEnforcesAADBinding(t *testing.T) {
	s := mustSealer(t, keyN(0x66))
	plaintext := []byte("sk-user-a-key")
	aadA := []byte("user-A|openai-key")
	aadB := []byte("user-B|openai-key")

	blob, err := s.Seal(plaintext, aadA)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	// Same master key, wrong AAD (a different user) → must not open.
	got, err := s.Open(blob, aadB)
	if err == nil {
		t.Fatal("blob for user A opened under user B's AAD — binding broken")
	}
	if got != nil {
		t.Fatalf("Open leaked plaintext on AAD mismatch: %q", got)
	}
	// Sanity: the correct AAD still opens.
	if _, err := s.Open(blob, aadA); err != nil {
		t.Fatalf("Open with correct AAD failed: %v", err)
	}
}

func TestNewSealerRejectsBadKeys(t *testing.T) {
	cases := map[string]string{
		"empty":          "",
		"not base64":     "@@@not-base64@@@",
		"too short":      base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x01}, 16)),
		"too long":       base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x01}, 48)),
		"one byte short": base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x01}, 31)),
	}
	for name, key := range cases {
		s, err := NewSealer(key)
		if err == nil {
			t.Errorf("%s: NewSealer accepted an invalid key", name)
		}
		if s != nil {
			t.Errorf("%s: NewSealer returned non-nil Sealer on error", name)
		}
	}
}

func TestNewSealerAcceptsValidKey(t *testing.T) {
	if _, err := NewSealer(keyN(0x77)); err != nil {
		t.Fatalf("NewSealer rejected a valid 32-byte key: %v", err)
	}
}

func TestOpenUnknownKeyIDErrorsNotPanic(t *testing.T) {
	s := mustSealer(t, keyN(0x88))
	blob, err := s.Seal([]byte("x"), []byte("aad"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	// Forge an unknown key_id byte; must return an error, never panic.
	blob[0] = 0x99
	got, err := s.Open(blob, []byte("aad"))
	if err == nil {
		t.Fatal("Open with unknown key_id succeeded — want error")
	}
	if got != nil {
		t.Fatalf("Open returned plaintext for unknown key_id: %q", got)
	}
}

func TestOpenRejectsTruncatedBlob(t *testing.T) {
	s := mustSealer(t, keyN(0xAA))
	// Shorter than key_id(1)+nonce(12).
	if _, err := s.Open([]byte{0x01, 0x02}, []byte("aad")); err == nil {
		t.Fatal("Open accepted a truncated blob — want error")
	}
}
