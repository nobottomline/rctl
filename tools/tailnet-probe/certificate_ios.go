package main

import (
	"net/http"

	"tailscale.com/ipn/localapi"
)

func init() {
	localapi.Register("cert/", func(h *localapi.Handler, w http.ResponseWriter, r *http.Request) {
		serveMobileCertificate(w, r, h.PermitWrite || h.PermitCert, h.LocalBackend().GetCertPEMWithValidity)
	})
}
