package main

import (
	"fmt"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics holds Prometheus metrics for the KMS service
type Metrics struct {
	requestsTotal   *prometheus.CounterVec
	requestDuration *prometheus.HistogramVec
	backendOps      *prometheus.CounterVec
}

// NewMetrics creates and registers Prometheus metrics
func NewMetrics() *Metrics {
	m := &Metrics{
		requestsTotal: prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Name: "kms_requests_total",
				Help: "Total HTTP requests",
			},
			[]string{"method", "path", "status"},
		),
		requestDuration: prometheus.NewHistogramVec(
			prometheus.HistogramOpts{
				Name:    "kms_request_duration_seconds",
				Help:    "Request duration in seconds",
				Buckets: prometheus.DefBuckets,
			},
			[]string{"method", "path"},
		),
		backendOps: prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Name: "kms_backend_operations_total",
				Help: "Backend operations",
			},
			[]string{"backend", "operation", "status"},
		),
	}

	// Register metrics
	prometheus.MustRegister(m.requestsTotal, m.requestDuration, m.backendOps)

	return m
}

// RecordRequest records metrics for an HTTP request
func (m *Metrics) RecordRequest(method, path string, status int, duration time.Duration) {
	m.requestsTotal.WithLabelValues(
		method,
		path,
		fmt.Sprintf("%d", status),
	).Inc()

	m.requestDuration.WithLabelValues(
		method,
		path,
	).Observe(duration.Seconds())
}

// RecordBackendOp records metrics for a backend operation
func (m *Metrics) RecordBackendOp(backend, operation, status string) {
	m.backendOps.WithLabelValues(
		backend,
		operation,
		status,
	).Inc()
}

// Handler returns the Prometheus HTTP handler
func (m *Metrics) Handler() http.Handler {
	return promhttp.Handler()
}
