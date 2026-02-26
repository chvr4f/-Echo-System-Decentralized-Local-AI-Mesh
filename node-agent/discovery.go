// node-agent/discovery.go
// Phase 6: mDNS service discovery — node-agent browses for the orchestrator
// so it can join the mesh automatically without manual IP configuration.

package main

import (
	"fmt"
	"log"
	"net"
	"time"

	"github.com/hashicorp/mdns"
)

const (
	mdnsServiceName = "_echo-mesh._tcp"
	mdnsDomain      = "local"
	mdnsTimeout     = 5 * time.Second
)

// discoverOrchestrator uses mDNS to find the orchestrator on the local network.
// It blocks up to mdnsTimeout while scanning. Returns the orchestrator URL
// (e.g. "http://192.168.1.10:8080") or an error if nothing was found.
func discoverOrchestrator() (string, error) {
	log.Println("[mDNS] Searching for orchestrator on the network...")

	entriesCh := make(chan *mdns.ServiceEntry, 4)
	var found *mdns.ServiceEntry

	// Run lookup in a goroutine — the library blocks until timeout
	go func() {
		_ = mdns.Lookup(mdnsServiceName, entriesCh)
	}()

	// Wait for the first result or timeout
	select {
	case entry := <-entriesCh:
		if entry != nil {
			found = entry
		}
	case <-time.After(mdnsTimeout):
	}

	// Drain remaining entries (non-blocking)
	go func() {
		for range entriesCh {
		}
	}()

	if found == nil {
		return "", fmt.Errorf("no orchestrator found via mDNS within %s", mdnsTimeout)
	}

	// Prefer IPv4
	ip := found.AddrV4
	if ip == nil {
		ip = found.Addr
	}
	if ip == nil {
		return "", fmt.Errorf("mDNS entry found but has no IP address")
	}

	url := fmt.Sprintf("http://%s:%d", ip.String(), found.Port)
	log.Printf("[mDNS] Found orchestrator at %s", url)
	return url, nil
}

// discoverOrchestratorWithRetry keeps trying mDNS discovery until the orchestrator
// is found. This is used when no -orchestrator flag is provided.
func discoverOrchestratorWithRetry() string {
	for {
		url, err := discoverOrchestrator()
		if err == nil {
			return url
		}
		log.Printf("[mDNS] %v — retrying in 3s", err)
		time.Sleep(3 * time.Second)
	}
}

// getPreferredOutboundIP returns this machine's preferred outbound IPv4 address.
// Used as AgentHost so the orchestrator knows how to reach this agent.
func getPreferredOutboundIP() string {
	// Try to find the outbound IP by dialing a public address (no actual connection)
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err == nil {
		defer conn.Close()
		if addr, ok := conn.LocalAddr().(*net.UDPAddr); ok {
			return addr.IP.String()
		}
	}
	// Fallback: scan interfaces
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "localhost"
	}
	for _, addr := range addrs {
		if ipNet, ok := addr.(*net.IPNet); ok && !ipNet.IP.IsLoopback() && ipNet.IP.To4() != nil {
			return ipNet.IP.String()
		}
	}
	return "localhost"
}
