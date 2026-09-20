package httpapi

import (
	"net"
	"net/http"
	"strings"
)

// clientIPFrom — X-Forwarded-For'dan client IP'sini GÜVENLİ biçimde çıkar.
//
// EN: XFF is a list the client can start. Anyone can send `X-Forwarded-For: 1.2.3.4` and, if you
//
//	read the first entry, they have just chosen their own rate-limit bucket — the limit becomes
//	opt-in. The only trustworthy part of the header is what YOUR proxies appended, so you count
//	back from the right by the number of proxies you actually run (trustedHops).
//	Read the first entry  → spoofable (P08-03b).
//	Read the socket peer  → everyone shares the ingress IP, one bucket for the world (P08-03a).
//	Read right-minus-hops → correct, and it requires knowing your own topology.
//
// TR: XFF, client'ın başlatabildiği bir listedir. Herkes `X-Forwarded-For: 1.2.3.4` gönderebilir
//
//	ve ilk girdiyi okuyorsan, kendi hız-limiti kovasını kendisi seçmiş olur — limit isteğe
//	bağlı hâle gelir. Header'ın güvenilir tek kısmı SENİN proxy'lerinin eklediğidir; bu yüzden
//	gerçekten çalıştırdığın proxy sayısı kadar SAĞDAN geri sayarsın (trustedHops).
//	İlk girdiyi oku      → taklit edilebilir (P08-03b).
//	Soket adresini oku   → herkes ingress IP'sini paylaşır, dünyaya tek kova (P08-03a).
//	Sağdan-hop kadar oku → doğru, ve kendi topolojini bilmeni gerektirir.
//
// [Topic · Konu: Güven sınırı, X-Forwarded-For]
func clientIPFrom(r *http.Request, trustedHops int, trustAnyXFF, ignoreXFF bool) string {
	peer := peerIP(r)
	if ignoreXFF {
		// TRAP_IGNORE_XFF: herkes ingress'in IP'sinde birleşir → tek kova (P08-03a)
		return peer
	}
	xff := r.Header.Get("X-Forwarded-For")
	if xff == "" {
		return peer
	}
	parts := strings.Split(xff, ",")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	if trustAnyXFF {
		// TRAP_TRUST_ANY_XFF: client'ın yazdığı ilk değere güven → limit atlatılabilir (P08-03b)
		return parts[0]
	}
	// Sağdan trustedHops kadar geri say: bizim proxy'lerimizin eklediği son değerler güvenilir.
	idx := len(parts) - trustedHops
	if idx < 0 {
		idx = 0
	}
	if idx >= len(parts) {
		return peer
	}
	return parts[idx]
}

func peerIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
