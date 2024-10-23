package kiln

import (
	"encoding/json"
	"log/slog"
	"net/http"
)

// InitExitStatus is the struct used to send the exit status of the main process to the host
// It's collected by init and sent to the host over vsock
type InitExitStatus struct {
	ExitCode  int64  `json:"exit_code"`
	OOMKilled bool   `json:"oom_killed"`
	Signal    int    `json:"signal"`
	Message   string `json:"message"`
}

func ExitStatusHandler(exitStatusChan chan InitExitStatus) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {

		var exitStatus InitExitStatus
		if err := json.NewDecoder(r.Body).Decode(&exitStatus); err != nil {
			http.Error(w, "Invalid exit status", http.StatusBadRequest)
			return
		}
		exitStatusChan <- exitStatus

		slog.Info("Received exit status", "exitCode", exitStatus.ExitCode, "oomKilled", exitStatus.OOMKilled, "message", exitStatus.Message)

		w.WriteHeader(http.StatusOK)
	}
}
