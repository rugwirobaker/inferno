package logging

import "time"

// LogEntry represents a single log entry in JSON Lines format.
type LogEntry struct {
	Timestamp string                 `json:"timestamp"`
	Level     string                 `json:"level"`
	Source    string                 `json:"source"`
	VMID      string                 `json:"vm_id"`
	Message   string                 `json:"message"`
	PID       int                    `json:"pid,omitempty"`
	Context   map[string]interface{} `json:"context,omitempty"`
}

// NewLogEntry creates a new log entry with the current timestamp.
func NewLogEntry(level, source, vmID, message string) *LogEntry {
	return &LogEntry{
		Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		Level:     level,
		Source:    source,
		VMID:      vmID,
		Message:   message,
	}
}
