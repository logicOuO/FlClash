//go:build !windows

package main

func platformTrafficProcessResolver() *trafficProcessResolver {
	return newTrafficProcessResolver(lookupNativeTrafficProcess, nil)
}
