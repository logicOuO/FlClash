//go:build !windows

package main

import "runtime"

func platformTrafficProcessResolver() *trafficProcessResolver {
	if runtime.GOOS == "android" {
		return nil
	}
	return newTrafficProcessResolver(lookupNativeTrafficProcess, nil)
}
