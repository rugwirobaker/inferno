package vm

import (
	"context"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/jpillora/backoff"
)

// Logger handles logging with queued entries and a retriable writer.
type Logger struct {
	writer       *retriableWriter
	logChan      chan string
	quitChan     chan struct{}
	wg           sync.WaitGroup
	flushTimeout time.Duration
	mu           sync.RWMutex // Protects access to writer.closed
	once         sync.Once    // Ensures Close is idempotent
	ctx          context.Context
	cancel       context.CancelFunc
}

// NewLogger initializes the Logger with a RetriableWriter.
// - factory: Function to create new WriterCloser instances.
// - queueSize: Size of the log entry queue.
// - flushTimeout: Maximum time to wait during flush.
func NewLogger(factory writerFactory, queueSize int, flushTimeout time.Duration) (*Logger, error) {
	retriableWriter, err := newRetriableWriter(factory)
	if err != nil {
		return nil, err
	}

	logger := &Logger{
		writer:       retriableWriter,
		logChan:      make(chan string, queueSize),
		quitChan:     make(chan struct{}),
		flushTimeout: flushTimeout, // Currently unused
	}

	logger.wg.Add(1)
	go logger.processLogs()

	return logger, nil
}

// processLogs listens to logChan and writes logs using RetriableWriter.
func (l *Logger) processLogs() {
	defer l.wg.Done()
	for {
		select {
		case logEntry, ok := <-l.logChan:
			if !ok {
				// Channel closed, exit the goroutine
				return
			}
			l.writeLog(logEntry)
		case <-l.quitChan:
			// Received quit signal, exit the goroutine
			return
		}
	}
}

// writeLog formats the log entry and writes it using fmt.Fprintln.
func (l *Logger) writeLog(logEntry string) {
	// Use fmt.Fprintln to format the log entry with a newline
	_, err := fmt.Fprintln(l.writer, logEntry)
	if err != nil {
		// Optionally handle the error, e.g., log to stderr
		// For demonstration, we silently drop the log
	}
}

// Log queues a log entry for processing.
// Returns io.EOF if the logger has been closed.
func (l *Logger) Log(entry string) error {
	// Acquire read lock to check if logger is closed
	l.mu.RLock()
	closed := l.writer.closed
	l.mu.RUnlock()

	if closed {
		return io.EOF
	}

	select {
	case l.logChan <- entry:
		// Successfully queued
		return nil
	default:
		// Queue is full, drop the log or handle accordingly
		return nil
	}
}

// Close is an alias for Flush.
func (l *Logger) Close() {
	l.once.Do(func() {
		// Signal to quit processing
		close(l.quitChan)
		// Wait for the goroutine to finish
		l.wg.Wait()
		// Close the log channel to release any blocked goroutines
		close(l.logChan)
		// Close the retriable writer
		l.writer.Close()
	})
}

// writerFactory defines a function that returns a new io.WriteCloser.
type writerFactory func() (io.WriteCloser, error)

// retriableWriter wraps an io.WriteCloser and provides retry logic with backoff.
type retriableWriter struct {
	factory writerFactory
	backoff backoff.Backoff

	mu     sync.RWMutex
	writer io.WriteCloser
	closed bool
}

// newRetriableWriter initializes a RetriableWriter with the initial WriterCloser.
// It configures the backoff strategy for retries.
func newRetriableWriter(factory writerFactory) (*retriableWriter, error) {
	writer, err := factory()
	if err != nil {
		return nil, err
	}

	// Configure the backoff strategy
	b := backoff.Backoff{
		Min:    100 * time.Millisecond, // Minimum backoff duration
		Max:    10 * time.Second,       // Maximum backoff duration
		Factor: 2,                      // Exponential factor
		Jitter: true,                   // Add jitter to prevent thundering herd
	}

	return &retriableWriter{
		factory: factory,
		backoff: b,
		writer:  writer,
	}, nil
}

// Write is the exported method that handles synchronization and delegates the actual
// write logic to the private write method.
// It returns io.EOF if the writer has been closed.
func (rw *retriableWriter) Write(p []byte) (n int, err error) {
	rw.mu.RLock()
	if rw.closed {
		rw.mu.RUnlock()
		return 0, io.EOF
	}
	rw.mu.RUnlock()

	// Acquire a write lock to ensure thread safety during write operations
	rw.mu.Lock()
	defer rw.mu.Unlock()

	// Double-check if the writer was closed while acquiring the lock
	if rw.closed {
		return 0, io.EOF
	}
	// Delegate the actual write logic to the private write method
	return rw.write(p)
}

// write encapsulates the core writing logic without handling synchronization.
// It attempts to write data and handles renewals upon failures.
func (rw *retriableWriter) write(p []byte) (n int, err error) {
	if rw.writer == nil {
		if err := rw.renew(); err != nil {
			return 0, err
		}
	}

	n, err = rw.writer.Write(p)
	if err != nil {
		// Attempt to renew the writer with retry and backoff
		if renewErr := rw.renew(); renewErr != nil {
			return n, renewErr
		}
		// Retry writing after renewal
		n, err = rw.writer.Write(p)
	}

	return n, err
}

// renew replaces the current WriterCloser with a new one from the factory.
// It retries with exponential backoff until successful or until the writer is closed.
// Assumes that the caller holds the write lock.
func (rw *retriableWriter) renew() error {
	if rw.closed {
		return io.EOF
	}
	// Close the existing writer if it's not nil
	if rw.writer != nil {
		rw.writer.Close()
		rw.writer = nil
	}
	// Reset the backoff
	rw.backoff.Reset()

	for {
		if rw.closed {
			return io.EOF
		}
		newWriter, err := rw.factory()
		if err != nil {
			// Retry with backoff
			wait := rw.backoff.Duration()
			<-time.After(wait)

			continue
		}
		rw.writer = newWriter

		return nil
	}
}

// Close closes the current WriterCloser and prevents further writes.
// After Close is called, any subsequent Write operations will return io.EOF.
func (rw *retriableWriter) Close() error {
	rw.mu.Lock()
	defer rw.mu.Unlock()

	if rw.closed {
		return nil
	}
	rw.closed = true
	if rw.writer != nil {
		err := rw.writer.Close()
		rw.writer = nil
		return err
	}
	return nil
}
