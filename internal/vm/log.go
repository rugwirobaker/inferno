package vm

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"sync"
	"time"

	"github.com/jpillora/backoff"
)

// LogSink handles logging with queued entries and a retriable writer.
// It acts as a sink for log messages, buffering and reliably writing them to the destination.
type LogSink struct {
	writer       io.WriteCloser
	logChan      chan string
	wg           sync.WaitGroup
	flushTimeout time.Duration
	closed       bool
	mu           sync.RWMutex // Protects access to writer.closed
	once         sync.Once    // Ensures Close is idempotent
	ctx          context.Context
	cancel       context.CancelFunc
}

type Options struct {
	QueueSize    int
	FlushTimeout time.Duration
}

type Option func(*Options)

func WithQueueSize(size int) Option {
	return func(o *Options) {
		o.QueueSize = size
	}
}

func WithFlushTimeout(timeout time.Duration) Option {
	return func(o *Options) {
		o.FlushTimeout = timeout
	}
}

// NewLogSink initializes the LogSink with a RetriableWriter.
// - factory: Function to create new WriterCloser instances.
// - queueSize: Size of the log entry queue.
// - flushTimeout: Maximum time to wait during flush.
func NewLogSink(ctx context.Context, factory WriterFactory, opts ...Option) (*LogSink, error) {
	ctx, cancel := context.WithCancel(ctx)

	var options = Options{
		QueueSize:    512,
		FlushTimeout: 2 * time.Second,
	}

	for _, opt := range opts {
		opt(&options)
	}

	retriableWriter, err := newRetriableWriter(ctx, factory)
	if err != nil {
		cancel()
		return nil, err
	}

	logSink := &LogSink{
		writer:       retriableWriter,
		logChan:      make(chan string, options.QueueSize),
		flushTimeout: options.FlushTimeout,
		ctx:          ctx,
		cancel:       cancel,
	}

	logSink.wg.Add(1)
	go logSink.processLogs()

	return logSink, nil
}

// processLogs listens to logChan and writes logs using RetriableWriter.
func (l *LogSink) processLogs() {
	defer l.wg.Done()
	for {
		select {
		case logEntry, ok := <-l.logChan:
			if !ok {
				// Channel closed, exit the goroutine
				return
			}
			l.writeLog(logEntry)
		case <-l.ctx.Done():
			l.Close()
			return

		}
	}
}

// writeLog formats the log entry and writes it using fmt.Fprintln.
func (l *LogSink) writeLog(logEntry string) {
	// Use fmt.Fprintln to format the log entry with a newline
	_, err := fmt.Fprintln(l.writer, logEntry)
	if err != nil {
		slog.Debug("Failed to write log entry", "error", err)
	}
}

// Log queues a log entry for processing.
// Returns io.EOF if the logger has been closed.
func (l *LogSink) Log(entry string) error {
	select {
	case <-l.ctx.Done():
		return io.EOF
	default:
	}

	l.mu.RLock()
	closed := l.closed
	l.mu.RUnlock()

	if closed {
		return io.EOF
	}

	select {
	case l.logChan <- entry:
		return nil
	default:
		// Queue is full, drop the log (or handle it as needed)
		return nil // For now, silently dropping logs if the queue is full
	}
}

// Close is an alias for Flush.
func (l *LogSink) Close() {
	l.once.Do(func() {
		l.mu.Lock()
		l.closed = true
		l.mu.Unlock()
		close(l.logChan)

		// Wait for the processLogs goroutine to finish
		done := make(chan struct{})
		go func() {
			l.wg.Wait()
			close(done)
		}()

		// Wait for FlushTimeout duration to allow logs to be processed
		flushTimeout := l.flushTimeout
		select {
		case <-done:
			// Successfully flushed all logs
		case <-time.After(flushTimeout):
			slog.Debug("Logger flush timeout exceeded")
		}
		// Close the writer
		l.writer.Close()
	})
}

// WriterFactory defines a function that returns a new io.WriteCloser.
type WriterFactory func(ctx context.Context) (io.WriteCloser, error)

func SocketWriterFactory(ctx context.Context, addr string) WriterFactory {
	return func(ctx context.Context) (io.WriteCloser, error) {
		var d net.Dialer
		return d.DialContext(ctx, "unix", addr)
	}
}

// retriableWriter wraps an io.WriteCloser and provides retry logic with backoff.
type retriableWriter struct {
	factory WriterFactory
	backoff backoff.Backoff

	mu     sync.RWMutex
	writer io.WriteCloser
	closed bool

	ctx context.Context
}

// newRetriableWriter initializes a RetriableWriter with the initial WriterCloser.
// It configures the backoff strategy for retries.
func newRetriableWriter(ctx context.Context, factory WriterFactory) (*retriableWriter, error) {
	writer, err := factory(ctx)
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
		ctx:     ctx,
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
func (rw *retriableWriter) renew() error {
	if rw.closed {
		return io.EOF
	}

	// Ensure the existing writer is closed
	if rw.writer != nil {
		err := rw.writer.Close()
		if err != nil {
			slog.Debug("Error closing writer during renew:", "error", err)
		}
		rw.writer = nil
	}

	// Reset the backoff
	rw.backoff.Reset()

	// Retry to get a new writer with backoff
	for {
		if rw.closed {
			return io.EOF
		}
		newWriter, err := rw.factory(rw.ctx)
		if err != nil {
			// Retry with backoff
			wait := rw.backoff.Duration()
			time.Sleep(wait)
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
