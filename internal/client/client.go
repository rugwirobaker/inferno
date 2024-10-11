package client

import "net/http"

type Client struct {
	userAgent string
	client    *http.Client
}
