//go:build !linux

package setup

import (
	"context"
	"errors"
)

func ServeHostUpdates(context.Context, string) error {
	return errors.New("host update service requires Linux")
}
