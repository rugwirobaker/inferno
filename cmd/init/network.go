package main

import (
	"fmt"
	"log/slog"
	"net"
	"os"

	"github.com/rugwirobaker/inferno/internal/image"
	"github.com/vishvananda/netlink"
)

func setupNetworking(config image.Config) error {
	lo, err := netlink.LinkByName("lo")
	if err != nil {
		return fmt.Errorf("error getting loopback interface: %v", err)
	}

	if err := netlink.LinkSetUp(lo); err != nil {
		return fmt.Errorf("error configuring loopback interface: %v", err)
	}

	// Configure IP and gateway
	for _, ipConfig := range config.IPs {
		slog.Info("Configuring networking", "IP", ipConfig.IP, "Gateway", ipConfig.Gateway, "Mask", ipConfig.Mask)

		eth0, err := netlink.LinkByName("eth0")
		if err != nil {
			return err
		}
		addr := &netlink.Addr{
			IPNet: &net.IPNet{
				IP:   ipConfig.IP,
				Mask: net.CIDRMask(ipConfig.Mask, 32),
			},
		}

		if err := netlink.AddrAdd(eth0, addr); err != nil {
			return fmt.Errorf("failed to add IP address %s to eth0: %w", addr.IPNet, err)
		}
		slog.Debug("Added IP address to eth0", "IP", ipConfig.IP, "Mask", ipConfig.Mask)

		if err := netlink.LinkSetUp(eth0); err != nil {
			return fmt.Errorf("failed to bring up interface eth0: %w", err)
		}
		slog.Debug("Interface eth0 is up")

		route := &netlink.Route{
			LinkIndex: eth0.Attrs().Index,
			Gw:        ipConfig.Gateway,
		}
		if err := netlink.RouteAdd(route); err != nil {
			return fmt.Errorf("failed to add default route via %s: %w", ipConfig.Gateway, err)
		}
		slog.Debug("Added default route", "Gateway", ipConfig.Gateway)
	}

	slog.Info("Networking setup completed")
	return nil
}

func writeResolvConf(entries image.EtcResolv) error {
	f, err := os.OpenFile("/etc/resolv.conf", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		return fmt.Errorf("error opening resolv.conf: %v", err)
	}
	defer f.Close()

	for i, entry := range entries.Nameservers {
		if i > 0 {
			if _, err := f.Write([]byte("\n")); err != nil {
				return fmt.Errorf("error writing newline to resolv.conf: %v", err)
			}
		}
		if _, err := fmt.Fprintf(f, "nameserver %s", entry); err != nil {
			return fmt.Errorf("error writing to resolv.conf file: %v", err)
		}
	}

	if _, err := f.Write([]byte("\n")); err != nil {
		return fmt.Errorf("error writing final newline to resolv.conf: %v", err)
	}

	return nil
}

var (
	defaultHosts = []image.EtcHost{
		{IP: "127.0.0.1", Host: "localhost localhost.localdomain localhost4 localhost4.localdomain4"},
		{IP: "::1", Host: "localhost localhost.localdomain localhost6 localhost6.localdomain6"},
		{IP: "fe00::0", Host: "ip6-localnet"},
		{IP: "ff00::0", Host: "ip6-mcastprefix"},
		{IP: "ff02::1", Host: "ip6-allnodes"},
		{IP: "ff02::2", Host: "ip6-allrouters"},
	}
	etchostPath = "/etc/hosts"
)

func writeEtcHost(hosts []image.EtcHost) error {
	slog.Debug("populating /etc/hosts")

	records := append(defaultHosts, hosts...)

	f, err := os.OpenFile(etchostPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("error opening /etc/hosts file: %v", err)
	}
	defer f.Close()

	for _, entry := range records {
		if entry.Desc != "" {
			_, err := fmt.Fprintf(f, "# %s\n%s\t%s\n", entry.Desc, entry.IP, entry.Host)
			if err != nil {
				return err
			}
		} else {
			_, err := fmt.Fprintf(f, "%s\t%s\n", entry.IP, entry.Host)
			if err != nil {
				return err
			}
		}
	}

	return nil
}
