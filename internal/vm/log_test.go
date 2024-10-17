package vm_test

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/rugwirobaker/inferno/internal/vm"
)

// MockWriter is a mock implementation of io.WriteCloser for testing purposes.
// It records all writes and can be configured to fail certain write attempts.
type MockWriter struct {
	mu             sync.Mutex
	WrittenData    bytes.Buffer
	WriteFailures  []bool  // Indicates whether each write should fail
	WriteResponses []error // Errors to return for each failed write
	writeIndex     int     // Current write attempt index
	CloseCalled    bool    // Whether Close was called
}

// Write simulates writing data, potentially failing based on configuration.
func (m *MockWriter) Write(p []byte) (n int, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.writeIndex < len(m.WriteFailures) && m.WriteFailures[m.writeIndex] {
		err = m.WriteResponses[m.writeIndex]
		m.writeIndex++
		return 0, err
	}

	n, err = m.WrittenData.Write(p)
	m.writeIndex++
	return n, err
}

// Close marks that Close was called.
func (m *MockWriter) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.CloseCalled = true
	return nil
}

// TestLoggerWriteToFile tests that Logger correctly writes log entries to a file.
func TestLoggerWriteToFile(t *testing.T) {
	// Create a temporary file
	tmpFile, err := os.CreateTemp("", "logger_test_*.log")
	if err != nil {
		t.Fatalf("Failed to create temp file: %v", err)
	}
	defer os.Remove(tmpFile.Name()) // Clean up

	// Define a factory that returns the temp file
	factory := func() (io.WriteCloser, error) {
		return tmpFile, nil
	}

	// Initialize the logger
	logLogger, err := vm.NewLogger(factory, 100, 2*time.Second)
	if err != nil {
		t.Fatalf("Failed to create logger: %v", err)
	}
	// Removed defer to call Close explicitly

	// Log some messages
	messages := []string{
		"First log entry.",
		"Second log entry.",
		"Third log entry.",
	}

	for _, msg := range messages {
		if err := logLogger.Log(msg); err != nil {
			t.Errorf("Failed to log message '%s': %v", msg, err)
		}
	}

	// Allow some time for logs to be written
	time.Sleep(500 * time.Millisecond)

	// Verify the writes
	content, err := os.ReadFile(tmpFile.Name())
	if err != nil {
		t.Fatalf("Failed to read log file: %v", err)
	}

	for _, msg := range messages {
		if !bytes.Contains(content, []byte(msg)) {
			t.Errorf("Log file does not contain expected message: %s", msg)
		}
	}

	// Close the logger to ensure all logs are flushed
	logLogger.Close()

	// Attempting to close again should not panic (idempotent)
	logLogger.Close()
}

// TestLoggerWriteToMockWriter tests that Logger correctly writes to a mock writer.
func TestLoggerWriteToMockWriter(t *testing.T) {
	// Initialize the mock writer
	mock := &MockWriter{}

	// Define a factory that returns the mock writer
	factory := func() (io.WriteCloser, error) {
		return mock, nil
	}

	// Initialize the logger
	logLogger, err := vm.NewLogger(factory, 100, 2*time.Second)
	if err != nil {
		t.Fatalf("Failed to create logger: %v", err)
	}
	// Removed defer to call Close explicitly

	// Log some messages
	messages := []string{
		"Test log entry one.",
		"Test log entry two.",
	}

	for _, msg := range messages {
		if err := logLogger.Log(msg); err != nil {
			t.Errorf("Failed to log message '%s': %v", msg, err)
		}
	}

	// Allow some time for logs to be written
	time.Sleep(500 * time.Millisecond)

	// Verify the writes
	for _, msg := range messages {
		if !bytes.Contains(mock.WrittenData.Bytes(), []byte(msg)) {
			t.Errorf("MockWriter does not contain expected message: %s", msg)
		}
	}

	// Close the logger to ensure all logs are flushed
	logLogger.Close()

	// Attempting to close again should not panic (idempotent)
	logLogger.Close()

	// Verify that Close was called
	if !mock.CloseCalled {
		t.Errorf("MockWriter.Close was not called")
	}
}

// TestConcurrentLogging tests that Logger can handle concurrent logging.
func TestConcurrentLogging(t *testing.T) {
	// Initialize the mock writer
	mock := &MockWriter{}

	// Define a factory that returns the mock writer
	factory := func() (io.WriteCloser, error) {
		return mock, nil
	}

	// Initialize the logger
	logLogger, err := vm.NewLogger(factory, 1000, 2*time.Second)
	if err != nil {
		t.Fatalf("Failed to create logger: %v", err)
	}
	defer logLogger.Close()

	// Number of goroutines and messages
	numGoroutines := 10
	numMessages := 100

	var wg sync.WaitGroup
	wg.Add(numGoroutines)

	// Start multiple goroutines to log messages concurrently
	for i := 0; i < numGoroutines; i++ {
		go func(id int) {
			defer wg.Done()
			for j := 0; j < numMessages; j++ {
				msg := fmt.Sprintf("Goroutine %d - Message %d", id, j)
				if err := logLogger.Log(msg); err != nil {
					t.Errorf("Failed to log message '%s': %v", msg, err)
				}
			}
		}(i)
	}

	// Wait for all goroutines to finish
	wg.Wait()

	// Allow some time for logs to be written
	time.Sleep(1 * time.Second)

	// Close the logger to ensure all logs are flushed
	logLogger.Close()

	// Attempting to close again should not panic (idempotent)
	logLogger.Close()

	// Verify that all messages were written
	expectedCount := numGoroutines * numMessages
	actualCount := bytes.Count(mock.WrittenData.Bytes(), []byte("Goroutine"))

	if actualCount != expectedCount {
		t.Errorf("Expected %d log entries, but got %d", expectedCount, actualCount)
	}
}

// TestLoggerCloseBehavior tests that Logger returns io.EOF after being closed.
func TestLoggerCloseBehavior(t *testing.T) {
	// Initialize the mock writer
	mock := &MockWriter{}

	// Define a factory that returns the mock writer
	factory := func() (io.WriteCloser, error) {
		return mock, nil
	}

	// Initialize the logger
	logLogger, err := vm.NewLogger(factory, 10, 2*time.Second)
	if err != nil {
		t.Fatalf("Failed to create logger: %v", err)
	}

	// Log a message
	err = logLogger.Log("Pre-close log entry.")
	if err != nil {
		t.Errorf("Failed to log message before close: %v", err)
	}

	// Close the logger
	logLogger.Close()

	// Attempting to close again should not panic (idempotent)
	logLogger.Close()

	// Attempt to log after closure
	err = logLogger.Log("Post-close log entry.")
	if !errors.Is(err, io.EOF) {
		t.Errorf("Expected io.EOF after close, but got: %v", err)
	}

	// Verify that the post-close message was not written
	if bytes.Contains(mock.WrittenData.Bytes(), []byte("Post-close log entry.")) {
		t.Errorf("Post-close log entry was unexpectedly written")
	}
}

// TestLoggerRetryLogic tests that Logger renews the writer upon write failure without retrying the write.
// TestLoggerRetryLogic tests that Logger renews the writer upon write failure without retrying the write.
// func TestLoggerRetryLogic(t *testing.T) {
// 	tests := []struct {
// 		name           string
// 		writeFailures  []bool  // Defines which write attempts should fail
// 		writeResponses []error // Errors to return for each failed write
// 		logMessage     string  // The log message to be written
// 		expectWritten  bool    // Whether the log message should be written successfully
// 		expectedWrites []int   // Expected number of writes per writer
// 	}{
// 		{
// 			name:           "Write succeeds on first attempt",
// 			writeFailures:  []bool{false},
// 			writeResponses: []error{nil},
// 			logMessage:     "Successful write",
// 			expectWritten:  true,
// 			expectedWrites: []int{1},
// 		},
// 		{
// 			name:           "Write fails and is not retried",
// 			writeFailures:  []bool{true},
// 			writeResponses: []error{errors.New("write failed")},
// 			logMessage:     "Failed write",
// 			expectWritten:  false,
// 			expectedWrites: []int{1, 0}, // First writer failed once, second writer not used
// 		},
// 	}

// 	for _, tc := range tests {
// 		t.Run(tc.name, func(t *testing.T) {
// 			// Initialize mock writers based on test case
// 			var mockWriters []*MockWriter
// 			for i := 0; i < len(tc.writeFailures); i++ {
// 				mock := &MockWriter{
// 					WriteFailures:  []bool{tc.writeFailures[i]},
// 					WriteResponses: []error{tc.writeResponses[i]},
// 				}
// 				mockWriters = append(mockWriters, mock)
// 			}

// 			// Define a factory that returns mock writers sequentially
// 			factory := func() (io.WriteCloser, error) {
// 				if len(mockWriters) == 0 {
// 					return nil, errors.New("no more mock writers available")
// 				}
// 				writer := mockWriters[0]
// 				mockWriters = mockWriters[1:]
// 				return writer, nil
// 			}

// 			// Initialize the logger
// 			logLogger, err := vm.NewLogger(factory, 10, 2*time.Second)
// 			if err != nil {
// 				t.Fatalf("Failed to create logger: %v", err)
// 			}
// 			defer logLogger.Close()

// 			// Log the message
// 			err = logLogger.Log(tc.logMessage)
// 			if err != nil && !errors.Is(err, io.EOF) {
// 				t.Errorf("Unexpected error during Log: %v", err)
// 			}

// 			// Allow some time for the write and potential renewal
// 			time.Sleep(500 * time.Millisecond)

// 			// Close the logger to ensure all logs are flushed
// 			logLogger.Close()

// 			// Verify the number of write attempts per writer
// 			for i, expected := range tc.expectedWrites {
// 				if i >= len(mockWriters) {
// 					t.Fatalf("Expected at least %d mock writers, but got %d", len(tc.expectedWrites), len(mockWriters))
// 				}
// 				actual := mockWriters[i].writeIndex
// 				if actual != expected {
// 					t.Errorf("Writer %d: expected %d write attempts, got %d", i+1, expected, actual)
// 				}
// 			}

// 			// Verify whether the log message was written
// 			written := false
// 			for _, mock := range mockWriters {
// 				if bytes.Contains(mock.WrittenData.Bytes(), []byte(tc.logMessage)) {
// 					written = true
// 					break
// 				}
// 			}

// 			if tc.expectWritten && !written {
// 				t.Errorf("Expected message '%s' to be written, but it was not", tc.logMessage)
// 			}

// 			if !tc.expectWritten && written {
// 				t.Errorf("Did not expect message '%s' to be written, but it was", tc.logMessage)
// 			}
// 		})
// 	}
// }
