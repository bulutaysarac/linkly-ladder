// Package stream — tıklama olaylarının dayanıklı taşınması (Kafka API / Redpanda).
package stream

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"time"
)

// ClickEvent — tel üzerindeki sözleşme.
//
// EN: Three fields matter beyond the payload. `EventID` makes the consumer able to be idempotent
//
//	(P06-01). `Version` makes it possible to change this struct later without a flag day
//	(P06-07). `At` is the producer's clock, not the consumer's — never derive "when" from when
//	you happened to process something.
//
// TR: Yükün ötesinde üç alan önemli. `EventID`, tüketicinin idempotent olabilmesini sağlar (P06-01).
//
//	`Version`, bu yapıyı ileride topyekûn bir geçiş günü olmadan değiştirebilmeyi (P06-07).
//	`At` üreticinin saatidir, tüketicinin değil — "ne zaman"ı, bir şeyi işlemeye denk geldiğin
//	andan asla türetme.
//
// [Topic · Konu: Olay şeması, idempotency, şema evrimi]
type ClickEvent struct {
	Version int       `json:"v"`
	EventID string    `json:"event_id"`
	Code    string    `json:"code"`
	At      time.Time `json:"at"`
}

const CurrentVersion = 1

func NewClickEvent(code string) ClickEvent {
	return ClickEvent{Version: CurrentVersion, EventID: newID(), Code: code, At: time.Now().UTC()}
}

func (e ClickEvent) Marshal() ([]byte, error) { return json.Marshal(e) }

func newID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
