package httpapi

import (
	"errors"
	"net/http"

	"github.com/bulutaysarac/linkly-ladder/14-modern/internal/auth"
)

// authenticate — Authorization: Bearer <key> doğrula, kimliği context'e koy.
//
// EN: The ordering matters and it is the opposite of what feels natural: authentication runs
//
//	BEFORE the expensive work but AFTER rate limiting by IP. Why? Because an unauthenticated
//	flood must be cheap to reject — if you authenticate first, every garbage request costs you
//	a hash and a lookup. Cheap checks first, expensive checks later: that is admission control.
//
// TR: Sıra önemli ve sezgiye ters: kimlik doğrulama, pahalı işten ÖNCE ama IP bazlı hız
//
//	sınırından SONRA çalışır. Neden? Çünkü kimliksiz bir sel ucuza reddedilmeli — önce kimlik
//	doğrularsan her çöp istek sana bir hash ve bir arama maliyeti çıkarır. Ucuz kontroller
//	önce, pahalı kontroller sonra: kabul kontrolü budur.
//
// [Topic · Konu: Kimlik doğrulama, kabul kontrolü sırası]
func authenticate(next http.Handler, keys *auth.Store, required bool, headerTenantTrap bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// TRAP_HEADER_TENANT: kiracıyı yine header'dan al. Kimlik doğrulama kodu duruyor ama
		// KARAR header'a dayanıyor — yani doğrulama dekoratif hâle geliyor (P13-01).
		if headerTenantTrap {
			if t := r.Header.Get("X-Tenant-ID"); t != "" {
				next.ServeHTTP(w, r.WithContext(auth.WithIdentity(r.Context(),
					auth.Identity{Tenant: t, Tier: "free", KeyID: "header"})))
				return
			}
		}

		id, err := keys.Verify(auth.BearerToken(r.Header.Get("Authorization")))
		switch {
		case err == nil:
			next.ServeHTTP(w, r.WithContext(auth.WithIdentity(r.Context(), id)))
		case errors.Is(err, auth.ErrNoCredentials) && !required:
			// Kimlik zorunlu değilse anonim devam: redirect gibi PUBLIC uçlar için.
			next.ServeHTTP(w, r)
		case errors.Is(err, auth.ErrNoCredentials):
			w.Header().Set("WWW-Authenticate", `Bearer realm="linkly"`)
			writeErr(w, r, http.StatusUnauthorized, "missing_credentials")
		default:
			// 401 mi 403 mü? 401 = "kim olduğunu bilmiyorum", 403 = "biliyorum ama yetkin yok".
			// Geçersiz bir anahtar birinci durumdur: kimliği DOĞRULAYAMADIK.
			writeErr(w, r, http.StatusUnauthorized, "invalid_credentials")
		}
	})
}
