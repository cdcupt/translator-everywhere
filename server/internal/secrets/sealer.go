// Package secrets provides the AES-256-GCM Sealer used to encrypt user secrets
// (the OpenAI API key) at rest. The master key lives only in the process
// environment (SECRET_ENCRYPTION_KEY), never in the database.
//
// Envelope layout produced by Seal / consumed by Open:
//
//	key_id (1 byte) ‖ nonce (12 bytes) ‖ ciphertext + GCM tag (len(plaintext)+16)
//
// key_id selects the master key so a future rotation can add a second key and
// re-seal without downtime. The AAD (authenticated, not stored) is assembled by
// the caller — it binds each blob to one user + slot, so a blob for user A will
// not Open under user B's AAD.
package secrets

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
)

// currentKeyID is the key_id byte written by Seal. Open accepts any key_id
// present in the keyring; a rotation adds a second entry keyed by a new byte.
const currentKeyID byte = 0x01

// masterKeyLen is the required AES-256 master key size in bytes.
const masterKeyLen = 32

// nonceLen is the AES-GCM nonce size; also asserted against the cipher below.
const nonceLen = 12

// Sealer encrypts and decrypts secret blobs. It is safe for concurrent use:
// cipher.AEAD is read-only after construction and crypto/rand is concurrency
// safe.
type Sealer struct {
	// keyring maps a key_id byte to its AEAD, so Open can decrypt blobs written
	// under any known key during a rotation. Seal always uses currentKeyID.
	keyring map[byte]cipher.AEAD
}

// NewSealer builds a Sealer from a base64-encoded 32-byte master key. It errors
// on empty, non-base64, or wrong-length input — this drives the graceful-degrade
// boot: a bad/absent key leaves the Sealer unbuilt and /secret/* returns 503
// rather than crashing the server.
func NewSealer(base64Key string) (*Sealer, error) {
	if base64Key == "" {
		return nil, errors.New("secrets: master key is empty")
	}
	key, err := base64.StdEncoding.DecodeString(base64Key)
	if err != nil {
		return nil, fmt.Errorf("secrets: master key is not valid base64: %w", err)
	}
	if len(key) != masterKeyLen {
		return nil, fmt.Errorf("secrets: master key must be %d bytes, got %d", masterKeyLen, len(key))
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("secrets: new cipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("secrets: new gcm: %w", err)
	}
	if aead.NonceSize() != nonceLen {
		return nil, fmt.Errorf("secrets: unexpected nonce size %d", aead.NonceSize())
	}

	return &Sealer{keyring: map[byte]cipher.AEAD{currentKeyID: aead}}, nil
}

// Seal returns key_id ‖ nonce ‖ gcm.Seal(plaintext, aad). A fresh random nonce
// is drawn for every call (never reused). aad is authenticated but not stored.
func (s *Sealer) Seal(plaintext, aad []byte) ([]byte, error) {
	aead := s.keyring[currentKeyID]
	if aead == nil {
		return nil, errors.New("secrets: no master key for current key_id")
	}

	nonce := make([]byte, nonceLen)
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("secrets: read nonce: %w", err)
	}

	// Preallocate the header so gcm.Seal appends the ciphertext after it in one
	// buffer: [key_id][nonce][ciphertext+tag].
	blob := make([]byte, 1+nonceLen, 1+nonceLen+len(plaintext)+aead.Overhead())
	blob[0] = currentKeyID
	copy(blob[1:], nonce)
	return aead.Seal(blob, nonce, plaintext, aad), nil
}

// Open reverses Seal. It reads the leading key_id byte, dispatches to the
// matching master key, and GCM-opens the remainder. Any failure — unknown
// key_id, truncated blob, tampered ciphertext/tag/nonce, or an AAD mismatch —
// returns a non-nil error and no plaintext (fail closed). It never panics.
func (s *Sealer) Open(blob, aad []byte) ([]byte, error) {
	if len(blob) < 1+nonceLen {
		return nil, errors.New("secrets: blob too short")
	}
	keyID := blob[0]
	aead := s.keyring[keyID]
	if aead == nil {
		return nil, fmt.Errorf("secrets: unknown key_id 0x%02x", keyID)
	}
	nonce := blob[1 : 1+nonceLen]
	ciphertext := blob[1+nonceLen:]
	plaintext, err := aead.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return nil, errors.New("secrets: decrypt failed")
	}
	return plaintext, nil
}
