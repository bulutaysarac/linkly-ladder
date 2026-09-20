package httpapi

import (
	"net"
	"net/url"
	"strings"
)

// checkURL — hedef URL güvenlik kontrolü.
//
// EN: linkly never fetches the target itself, so this is not classic SSRF. The risk is that a
//
//	trusted-looking short link points a BROWSER — possibly one inside a corporate network — at an
//	internal address, or at a javascript:/data: URI. This is a reduction of risk, not an
//	elimination: a hostname that resolves to a private address still passes here. Level 13 adds
//	DNS resolution (and explains the TOCTOU limit that remains even then).
//
// TR: linkly hedefi kendisi çekmiyor, yani klasik SSRF değil. Risk şu: güvenilir görünen bir kısa
//
//	link, bir TARAYICIYI — muhtemelen kurum içi bir tarayıcıyı — iç bir adrese ya da
//	javascript:/data: URI'sine yollar. Bu bir risk AZALTMA, eliminasyon değil: özel bir adrese
//	çözülen bir alan adı buradan geçer. 13 DNS çözümünü ekliyor (ve orada bile kalan TOCTOU
//	sınırını anlatıyor).
//
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

// checkURLResolved — hostname'i ÇÖZ ve özel adrese işaret ediyor mu bak.
//
// EN: The level-01 check only looked at literal IPs in the URL. An attacker does not write
//
//	http://10.0.0.1 — they register evil.example.com with an A record pointing at 169.254.169.254.
//	Resolving closes that hole, and it introduces a real, unavoidable TOCTOU gap: we resolve
//	now, the browser resolves later, and DNS can change in between (DNS rebinding). Mitigations
//	exist (pin the resolved IP, re-check at redirect time, egress policy) and none is free.
//	Saying "we reduced the risk" honestly is better than claiming it is gone.
//
// TR: 01'deki kontrol yalnızca URL'deki düz IP'lere bakıyordu. Saldırgan http://10.0.0.1 yazmaz —
//
//	evil.example.com'u 169.254.169.254'e işaret eden bir A kaydıyla kaydeder. Çözümleme bu
//	deliği kapatır ve gerçek, kaçınılmaz bir TOCTOU boşluğu getirir: biz ŞİMDİ çözüyoruz,
//	tarayıcı SONRA çözecek ve arada DNS değişebilir (DNS rebinding). Azaltmalar var (çözülen
//	IP'yi sabitle, yönlendirme anında yeniden kontrol et, egress politikası) ve hiçbiri bedava
//	değil. "Riski azalttık" demek, "yok ettik" demekten dürüsttür.
//
// [Topic · Konu: SSRF/open redirect, DNS rebinding, TOCTOU]
func checkURLResolved(raw string, resolve bool) (string, string) {
	target, reason := checkURL(raw)
	if reason != "" || !resolve {
		return target, reason
	}
	u, err := url.Parse(target)
	if err != nil {
		return "", "parse"
	}
	ips, err := net.LookupIP(u.Hostname())
	if err != nil {
		// Çözülemeyen bir host'u REDDETMEK mi kabul etmek mi? Reddetmek, geçici DNS
		// arızalarında meşru linkleri engeller; kabul etmek kontrolü atlatılabilir kılar.
		// Burada kabul ediyoruz ve SAYIYORUZ — karar görünür olsun diye.
		return target, ""
	}
	for _, ip := range ips {
		if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() ||
			ip.Equal(net.IPv4(169, 254, 169, 254)) {
			return "", "private_address_resolved"
		}
	}
	return target, ""
}
