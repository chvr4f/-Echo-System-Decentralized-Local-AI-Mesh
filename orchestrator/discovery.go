// orchestrator/discovery.go
// Phase 6: mDNS service advertisement so node-agents can auto-discover
// the orchestrator without manual IP configuration.

package main

import (
	"fmt"
	"log"
	"net"
	"os"

	"github.com/hashicorp/mdns"
)

const (
	mdnsServiceName  = "_echo-mesh._tcp"
	mdnsDomain       = "local."
	orchestratorPort = 8080
)

// startMDNS advertises the orchestrator as an mDNS service on the local network.
// Node-agents browse for "_echo-mesh._tcp" to find the orchestrator automatically.
// Returns a cleanup function that should be called on shutdown.
func startMDNS() (func(), error) {
	hostname, _ := os.Hostname()

	// Get the machine's non-loopback IP so agents on other hosts can reach us
	ips := getOutboundIPs()
	log.Printf("[mDNS] Advertising %s on port %d (IPs: %v)", mdnsServiceName, orchestratorPort, ips)

	// Build the mDNS service entry
	info := []string{
		fmt.Sprintf("echo-mesh orchestrator on %s", hostname),
	}
	service, err := mdns.NewMDNSService(
		hostname,         // instance name
		mdnsServiceName,  // service type
		mdnsDomain,       // domain
		"",               // host name (empty = use OS hostname)
		orchestratorPort, // port
		ips,              // IPs to advertise
		info,             // TXT records
	)
	if err != nil {
		return nil, fmt.Errorf("mdns service creation failed: %w", err)
	}

	server, err := mdns.NewServer(&mdns.Config{Zone: service})
	if err != nil {
		return nil, fmt.Errorf("mdns server start failed: %w", err)
	}

	log.Printf("[mDNS] Broadcasting orchestrator as %s.%s", mdnsServiceName, mdnsDomain)

	cleanup := func() {
		log.Println("[mDNS] Stopping mDNS advertisement")
		server.Shutdown()
	}
	return cleanup, nil
}

// getOutboundIPs returns non-loopback IPv4 addresses on this machine.
func getOutboundIPs() []net.IP {
	var result []net.IP

	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}

	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok {
			continue
		}
		ip := ipNet.IP
		// Skip loopback and IPv6 for simplicity
		if ip.IsLoopback() || ip.To4() == nil {
			continue
		}
		result = append(result, ip)
	}
	return result
}
