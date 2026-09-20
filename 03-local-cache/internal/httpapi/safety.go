package httpapi

import (
	"net"
	"net/url"
	"strings"
)

// checkURL — hedef URL güvenlik kontrolü.
//
// EN: linkly never fetches the target itself, so this is not classic SSRF. The risk is that a
//     trusted-looking short link points a BROWSER — possibly one inside a corporate network — at an
//     internal address, or at a javascript:/data: URI. This is a reduction of risk, not an
//     elimination: a hostname that resolves to a private address still passes here. Level 13 adds
//     DNS resolution (and explains the TOCTOU limit that remains even then).
// TR: linkly hedefi kendisi çekmiyor, yani klasik SSRF değil. Risk şu: güvenilir görünen bir kısa
//     link, bir TARAYICIYI — muhtemelen kurum içi bir tarayıcıyı — iç bir adrese ya da
//     javascript:/data: URI'sine yollar. Bu bir risk AZALTMA, eliminasyon değil: özel bir adrese
//     çözülen bir alan adı buradan geçer. 13 DNS çözümünü ekliyor (ve orada bile kalan TOCTOU
//     sınırını anlatıyor).
// [Topic · Konu: Open redirect, giriş doğrulama]
func checkURL(raw string) (string, string) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", "parse"
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", "parse"
	}
	// Allowlist: reddedilecekleri saymak yerine kabul edilecekleri say. Denylist her zaman eksiktir
	// (javascript:, data:, vbscript:, file:, intent:, …); allowlist varsayılan olarak kapalıdır.
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", "scheme"
	}
	host := u.Hostname()
	if host == "" {
		return "", "host"
	}
	if ip := net.ParseIP(host); ip != nil {
		if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
			return "", "private_address"
		}
	}
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".internal") {
		return "", "private_address"
	}
	return u.String(), ""
}
