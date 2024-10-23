package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"

	"github.com/rugwirobaker/inferno/internal/sys"
)

// KernelStyleHandler implements the slog.Handler interface for kernel-style logging.
type KernelStyleHandler struct {
	writer    io.Writer           // The destination for log messages
	opts      slog.HandlerOptions // Options, including log level filtering
	source    string
	formatter func(float64, slog.Level, string, string) string
}

// NewKernelStyleHandler creates a new KernelStyleHandler.
// It takes an io.Writer (e.g., os.Stdout or a file) and HandlerOptions with a slog.Leveler.
func NewKernelStyleHandler(writer io.Writer, source string, opts slog.HandlerOptions) *KernelStyleHandler {
	return &KernelStyleHandler{
		writer:    writer,
		opts:      opts,
		source:    source,
		formatter: defaultFormatter,
	}
}

// Enabled checks if the provided log level is enabled by comparing it to the configured level.
func (h *KernelStyleHandler) Enabled(_ context.Context, level slog.Level) bool {
	// If Leveler is set, use it to filter log levels; otherwise, default to logging all levels.
	if h.opts.Level != nil {
		return level >= h.opts.Level.Level()
	}
	return true // Log everything if no level is set
}

// Handle processes the log record and outputs it in kernel-style format.
func (h *KernelStyleHandler) Handle(_ context.Context, record slog.Record) error {
	// Get the system uptime for the timestamp
	uptimeSeconds, err := sys.Uptime()
	if err != nil {
		return fmt.Errorf("error getting uptime: %w", err)
	}

	message := h.formatter(uptimeSeconds, record.Level, h.source, record.Message)
	_, err = fmt.Fprint(h.writer, message)
	if err != nil {
		return fmt.Errorf("error writing log: %w", err)
	}
	return nil
}

// WithAttrs returns a new Handler with additional attributes, which are ignored in this handler.
func (h *KernelStyleHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	// We don't use attributes in this handler, so just return the handler itself.
	return h
}

// WithGroup returns a new Handler with the given group name, which we don't use in this handler.
func (h *KernelStyleHandler) WithGroup(name string) slog.Handler {
	// We don't use groups in this handler, so just return the handler itself.
	return h
}

// defaultFormatter is the default log message formatter for kernel-style logs.
// It takes uptime, log level, subsystem, and the message to be logged.
func defaultFormatter(uptime float64, level slog.Level, subsystem string, message string) string {
	// Determine the number of characters before the decimal point in the uptime
	uptimeStr := fmt.Sprintf("%.6f", uptime)
	beforeDecimal := len(uptimeStr[:len(uptimeStr)-7]) // the part before the decimal

	// Use dynamic padding based on the number of digits before the decimal point
	padding := 6 - beforeDecimal
	if padding < 0 {
		padding = 0
	}

	return fmt.Sprintf("[%"+fmt.Sprintf("%d", padding+7)+".6f] %-5s [%s]: %s\n", uptime, level.String(), subsystem, message)
}
