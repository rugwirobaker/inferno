package vm_test

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/rugwirobaker/inferno/internal/vm"
	"github.com/stretchr/testify/assert"
)

// set test environment to enable slog debug logs
func init() {
	slog.SetLogLoggerLevel(slog.LevelDebug)
}

// MockWriter simulates multiple writers with the ability to fail.
type MockWriter struct {
	mu             sync.Mutex
	WrittenData    bytes.Buffer
	WriteFailures  []bool  // Indicates whether each write should fail
	WriteResponses []error // Errors to return for each failed write
	writeIndex     int     // Current write attempt index
	CloseCalled    bool    // Whether Close was called
	WriteDone      chan struct{}
}

// Write simulates writing data, potentially failing based on configuration.
func (m *MockWriter) Write(p []byte) (n int, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	defer func() {
		if m.WriteDone != nil {
			m.WriteDone <- struct{}{}
		}
	}()

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
	assert := assert.New(t)

	// Create a temporary file
	tmpFile, err := os.CreateTemp("", "logger_test_*.log")
	assert.NoError(err, "Failed to create temp file")
	defer os.Remove(tmpFile.Name()) // Clean up

	// Define a factory that returns the temp file
	factory := func(ctx context.Context) (io.WriteCloser, error) {
		return tmpFile, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Initialize the logger with functional options
	logger, err := vm.NewLogSink(ctx, factory, vm.WithQueueSize(100), vm.WithFlushTimeout(2*time.Second))
	assert.NoError(err, "Failed to create logger")
	defer logger.Close()

	// Log some messages
	messages := []string{
		"First log entry.",
		"Second log entry.",
		"Third log entry.",
	}

	for _, msg := range messages {
		err := logger.Log(msg)
		assert.NoError(err, fmt.Sprintf("Failed to log message '%s'", msg))
	}

	// Allow some time for logs to be written
	time.Sleep(500 * time.Millisecond)

	// Verify the writes
	content, err := os.ReadFile(tmpFile.Name())
	assert.NoError(err, "Failed to read log file")

	contentStr := string(content)
	for _, msg := range messages {
		assert.Contains(contentStr, msg, fmt.Sprintf("Log file does not contain expected message: %s", msg))
	}
}

// TestLoggerWriteToMockWriter tests that Logger correctly writes to a mock writer.
func TestLoggerWriteToMockWriter(t *testing.T) {
	assert := assert.New(t)

	// Initialize the mock writer
	mock := &MockWriter{}

	// Define a factory that returns the mock writer
	factory := func(ctx context.Context) (io.WriteCloser, error) {
		return mock, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Initialize the logger with functional options
	logger, err := vm.NewLogSink(ctx, factory, vm.WithQueueSize(100), vm.WithFlushTimeout(2*time.Second))
	assert.NoError(err, "Failed to create logger")
	defer logger.Close()

	// Log some messages
	messages := []string{
		"Test log entry one.",
		"Test log entry two.",
	}

	for _, msg := range messages {
		err := logger.Log(msg)
		assert.NoError(err, fmt.Sprintf("Failed to log message '%s'", msg))
	}

	// Allow some time for logs to be written
	time.Sleep(500 * time.Millisecond)

	// Verify the writes
	writtenContent := mock.WrittenData.String()
	for _, msg := range messages {
		assert.Contains(writtenContent, msg, fmt.Sprintf("MockWriter does not contain expected message: %s", msg))
	}
	// Verify that Close was called
	logger.Close()
	assert.True(mock.CloseCalled, "MockWriter.Close was not called")
}

// TestConcurrentLogging tests that Logger can handle concurrent logging.
func TestConcurrentLogging(t *testing.T) {
	assert := assert.New(t)

	// Initialize the mock writer
	mock := &MockWriter{}

	// Define a factory that returns the mock writer
	factory := func(ctx context.Context) (io.WriteCloser, error) {
		return mock, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// Initialize the logger with functional options
	logger, err := vm.NewLogSink(ctx, factory, vm.WithQueueSize(1000), vm.WithFlushTimeout(2*time.Second))
	assert.NoError(err, "Failed to create logger")
	defer logger.Close()

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
				err := logger.Log(msg)
				assert.NoError(err, fmt.Sprintf("Failed to log message '%s'", msg))
			}
		}(i)
	}

	// Wait for all goroutines to finish
	wg.Wait()

	// Allow some time for logs to be written
	time.Sleep(1 * time.Second)

	// Verify that all messages were written
	expectedCount := numGoroutines * numMessages
	actualCount := bytes.Count(mock.WrittenData.Bytes(), []byte("Goroutine"))

	assert.Equal(expectedCount, actualCount, fmt.Sprintf("Expected %d log entries, but got %d", expectedCount, actualCount))
}

// TestLoggerCloseBehavior tests that Logger returns io.EOF after being closed.
func TestLoggerCloseBehavior(t *testing.T) {
	assert := assert.New(t)

	// Initialize the mock writer
	mock := &MockWriter{}

	// Define a factory that returns the mock writer
	factory := func(ctx context.Context) (io.WriteCloser, error) {
		return mock, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Initialize the logger with functional options
	logger, err := vm.NewLogSink(ctx, factory, vm.WithQueueSize(10), vm.WithFlushTimeout(2*time.Second))
	assert.NoError(err, "Failed to create logger")

	// Log a message
	err = logger.Log("Pre-close log entry.")
	assert.NoError(err, "Failed to log message before close")

	// Close the logger
	logger.Close()

	// Attempting to close again should not panic (idempotent)
	logger.Close()

	// Attempt to log after closure
	err = logger.Log("Post-close log entry.")
	assert.ErrorIs(err, io.EOF, "Expected io.EOF after close")

	// Verify that the post-close message was not written
	assert.NotContains(mock.WrittenData.Bytes(), []byte("Post-close log entry."), "Post-close log entry was unexpectedly written")
}

func TestLoggerContextCancellation(t *testing.T) {
	assert := assert.New(t)

	// Initialize the mock writer
	mock := &MockWriter{WriteFailures: []bool{false}}

	// Create a factory that returns the mock writer and accepts a context
	factory := func(ctx context.Context) (io.WriteCloser, error) {
		return mock, nil
	}

	// Initialize the logger with a context
	ctx, cancel := context.WithCancel(context.Background())

	logger, err := vm.NewLogSink(ctx, factory, vm.WithQueueSize(10), vm.WithFlushTimeout(2*time.Second))
	assert.NoError(err)

	// Log a message before context cancellation
	err = logger.Log("Log entry before cancellation.")
	assert.NoError(err, "Failed to log message before context cancellation")

	// Wait a short time to ensure the message is logged
	time.Sleep(100 * time.Millisecond)

	// Cancel the context to simulate shutdown
	cancel()

	// Attempt to log after context cancellation
	err = logger.Log("Log entry after cancellation.")
	assert.ErrorIs(err, io.EOF, "Expected io.EOF after context cancellation")

	// Verify that the post-cancel message was not written
	writtenContent := mock.WrittenData.String()
	assert.NotContains(writtenContent, "Log entry after cancellation.", "Log entry after cancellation was unexpectedly written")

	// Close the logger explicitly (no-op since it's already closed)
	logger.Close()
}

func TestLoggerWriterRenewal(t *testing.T) {
	assert := assert.New(t)

	// Create two mock writers to simulate renewal
	mockWriter1 := &MockWriter{
		WriteFailures:  []bool{true}, // The first writer fails on the first write
		WriteResponses: []error{fmt.Errorf("mock failure")},
		WriteDone:      make(chan struct{}, 1),
	}
	mockWriter2 := &MockWriter{
		WriteDone: make(chan struct{}, 1),
	}

	// Create a factory that returns mockWriter1 first, then mockWriter2
	factory := func(ctx context.Context) (io.WriteCloser, error) {
		if !mockWriter1.CloseCalled {
			return mockWriter1, nil
		}
		return mockWriter2, nil
	}

	// Initialize the logger
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	logger, err := vm.NewLogSink(ctx, factory, vm.WithQueueSize(10), vm.WithFlushTimeout(2*time.Second))
	assert.NoError(err, "Failed to create logger")
	defer logger.Close()

	// Log an entry that should trigger the first writer's failure
	err = logger.Log("first log entry")
	assert.NoError(err, "Expected no error when logging the first entry despite failure")

	// Wait for the first write attempt to complete
	select {
	case <-mockWriter1.WriteDone:
		// Write attempted
	case <-time.After(1 * time.Second):
		t.Fatal("Timed out waiting for first write attempt")
	}

	// Verify the first writer was closed after the failure
	assert.True(mockWriter1.CloseCalled, "Expected first writer to be closed after failure")

	// Log another entry which should use the second writer
	err = logger.Log("second log entry")
	assert.NoError(err, "Expected no error when logging the second entry after renewal")

	// Wait for the second write attempt to complete
	select {
	case <-mockWriter2.WriteDone:
		// Write attempted
	case <-time.After(1 * time.Second):
		t.Fatal("Timed out waiting for second write attempt")
	}

	// Verify that the second writer received the second log entry
	assert.Contains(mockWriter2.WrittenData.String(), "second log entry", "Expected second writer to contain 'second log entry'")
}
