// Package shortcode — kısa kod üretimi.
//
// EN: Two changes from level 00, both of which look cosmetic and are not:
//  1. crypto/rand instead of math/rand — a predictable code is an enumeration invite.
//  2. 7 characters instead of 4 — 62^7 ≈ 3.5e12 vs 62^4 ≈ 1.5e7. At 4 chars the birthday paradox
//     makes collisions routine (measured at level 00: 3 collisions in 10k links).
//
// TR: 00'a göre iki değişiklik; ikisi de kozmetik görünüp değil:
//  1. math/rand yerine crypto/rand — tahmin edilebilir kod, tarama daveti.
//  2. 4 yerine 7 karakter — 62^7 ≈ 3.5e12. 4 karakterde doğum günü paradoksu çakışmayı
//     rutin yapıyordu (00'da ölçüldü: 10 bin linkte 3 çakışma).
//
// [Topic · Konu: Anahtar üretimi, doğum günü paradoksu, enumeration]
package shortcode

import (
	"crypto/rand"
	"math/big"
)

const Alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

// New, kriptografik olarak güvenli rastgele n karakterlik kod üretir.
func New(n int) (string, error) {
	b := make([]byte, n)
	max := big.NewInt(int64(len(Alphabet)))
	for i := range b {
		idx, err := rand.Int(rand.Reader, max)
		if err != nil {
			return "", err
		}
		b[i] = Alphabet[idx.Int64()]
	}
	return string(b), nil
}

// Valid, bir kodun alfabemize uyup uymadığını söyler (tarama isteklerini ucuza elemek için).
func Valid(code string, maxLen int) bool {
	if code == "" || len(code) > maxLen {
		return false
	}
	for i := 0; i < len(code); i++ {
		found := false
		for j := 0; j < len(Alphabet); j++ {
			if code[i] == Alphabet[j] {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}
