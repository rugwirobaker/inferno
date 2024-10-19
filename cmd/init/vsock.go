package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"

	"github.com/mdlayher/vsock"
)

func NewVsockClient(ctx context.Context, port uint32) (*http.Client, error) {
	// Dial to the host server over vsock
	conn, err := vsock.Dial(2, port, nil) // Connect to host CID (2) and the specified port
	if err != nil {
		return nil, fmt.Errorf("failed to connect to host via vsock: %v", err)
	}

	// Create an HTTP client that uses the VSOCK connection
	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
				return conn, nil
			},
		},
	}
	return client, nil
}

func sendExitStatus(ctx context.Context, client *http.Client, exitStatus ExitStatus) error {
	// Encode the exit status as JSON
	body, err := json.Marshal(exitStatus)
	if err != nil {
		return fmt.Errorf("failed to encode exit status: %v", err)
	}

	// Create HTTP POST request
	req, err := http.NewRequestWithContext(ctx, "POST", "/exit", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("failed to create HTTP request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")

	// Send the request
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to send exit status: %v", err)
	}
	defer resp.Body.Close()

	// Check response
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("failed to send exit status, server responded with: %s", resp.Status)
	}

	return nil
}
