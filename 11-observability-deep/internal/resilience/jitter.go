package resilience

import (
	"math/rand"
	"time"
)

// jitter — geri çekilme süresine ±%50 rastgelelik ekler.
func jitter(d time.Duration) time.Duration {
	if d <= 0 {
		return 0
	}
	return time.Duration(rand.Int63n(int64(d))) - d/2
}
