package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
)

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
