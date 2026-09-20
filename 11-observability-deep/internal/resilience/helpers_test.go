package resilience

import (
	"net/http"
	"net/http/httptest"
)

// blockingExcept — verilen yollar dışındaki istekleri kanal kapanana kadar bloklar.
func blockingExcept(block <-chan struct{}, free ...string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, p := range free {
			if r.URL.Path == p {
				w.WriteHeader(http.StatusOK)
				return
			}
		}
		<-block
		w.WriteHeader(http.StatusOK)
	})
}

func httpHandlerFunc(fn func()) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fn()
		w.WriteHeader(http.StatusOK)
	})
}

func newRecorder() *httptest.ResponseRecorder { return httptest.NewRecorder() }
func newRequest(path string) *http.Request    { return httptest.NewRequest("GET", path, nil) }
