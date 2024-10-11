// cmd/kiln/main.go
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/rugwirobaker/inferno/internal/kiln"
)

func main() {
	ctx := context.Background()
	cmd := kiln.New()

	if err := cmd.ExecuteContext(ctx); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}
