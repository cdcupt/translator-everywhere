package auth

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"sync"
	"time"
)

// jwk is one key from a JWKS document (RSA only — both Apple and Google sign
// identity tokens with RS256).
type jwk struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Use string `json:"use"`
	Alg string `json:"alg"`
	N   string `json:"n"`
	E   string `json:"e"`
}

type jwksDocument struct {
	Keys []jwk `json:"keys"`
}

// jwksCache fetches and caches a provider's JWKS, keyed by kid, refreshing when
// a requested kid is missing (handles provider key rotation) or the TTL lapses.
type jwksCache struct {
	url        string
	httpClient *http.Client
	ttl        time.Duration
	now        func() time.Time

	mu        sync.Mutex
	keys      map[string]*rsa.PublicKey
	fetchedAt time.Time
}

func newJWKSCache(url string, client *http.Client, ttl time.Duration) *jwksCache {
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	return &jwksCache{
		url:        url,
		httpClient: client,
		ttl:        ttl,
		now:        time.Now,
		keys:       map[string]*rsa.PublicKey{},
	}
}

// key returns the RSA public key for kid, refreshing the cache on a miss or
// when the cached document is stale.
func (c *jwksCache) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if k, ok := c.keys[kid]; ok && c.now().Sub(c.fetchedAt) < c.ttl {
		return k, nil
	}
	if err := c.refreshLocked(ctx); err != nil {
		// Serve a stale-but-present key rather than failing on a transient
		// fetch error.
		if k, ok := c.keys[kid]; ok {
			return k, nil
		}
		return nil, err
	}
	k, ok := c.keys[kid]
	if !ok {
		return nil, fmt.Errorf("auth: no JWKS key for kid %q", kid)
	}
	return k, nil
}

func (c *jwksCache) refreshLocked(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url, nil)
	if err != nil {
		return err
	}
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("auth: JWKS fetch %s returned %d", c.url, resp.StatusCode)
	}

	var doc jwksDocument
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return fmt.Errorf("auth: decode JWKS: %w", err)
	}

	keys := make(map[string]*rsa.PublicKey, len(doc.Keys))
	for _, k := range doc.Keys {
		if k.Kty != "RSA" {
			continue
		}
		pub, err := k.rsaPublicKey()
		if err != nil {
			return err
		}
		keys[k.Kid] = pub
	}
	c.keys = keys
	c.fetchedAt = c.now()
	return nil
}

func (k jwk) rsaPublicKey() (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(k.N)
	if err != nil {
		return nil, fmt.Errorf("auth: decode JWK modulus: %w", err)
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(k.E)
	if err != nil {
		return nil, fmt.Errorf("auth: decode JWK exponent: %w", err)
	}
	e := new(big.Int).SetBytes(eBytes)
	if !e.IsInt64() || e.Int64() > int64(^uint32(0)) {
		return nil, fmt.Errorf("auth: JWK exponent out of range")
	}
	return &rsa.PublicKey{
		N: new(big.Int).SetBytes(nBytes),
		E: int(e.Int64()),
	}, nil
}
