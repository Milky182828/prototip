package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"prototip/internal/panel/cli"
	"prototip/web"
)

var version = "dev"

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := cli.Run(ctx, os.Args[1:], version, web.Dist()); err != nil {
		fmt.Fprintln(os.Stderr, "prototip:", err)
		os.Exit(1)
	}
}
