# Multi-Machine Setup Guide

**Connect multiple aiteamforge installations for coordinated development**

---

## Table of Contents

- [Overview](#overview)
- [Fleet Monitor Architecture](#fleet-monitor-architecture)
- [Tailscale Setup](#tailscale-setup)
- [Server Configuration](#server-configuration)
- [Client Configuration](#client-configuration)
- [Hybrid Configuration](#hybrid-configuration)
- [Service Discovery](#service-discovery)
- [Shared Kanban State](#shared-kanban-state)
- [Monitoring Agents](#monitoring-agents)
- [Troubleshooting Network Issues](#troubleshooting-network-issues)

---

## Overview

AITeamForge supports multi-machine setups through **Fleet Monitor**, a distributed system for coordinating development across multiple machines.

### Use Cases

- **Main workstation + secondary machines** - Distribute workload across multiple Macs
- **Office + home machines** - Continue work seamlessly between locations
- **Team collaboration** - Multiple developers sharing kanban state
- **Build farm** - Dedicated machines for CI/CD and testing

### Architecture Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| **Standalone** | Single machine, no networking | Default, single-machine development |
| **Server** | Central coordinator, hosts Fleet Monitor | Main workstation, always running |
| **Client** | Connects to server, reports status | Secondary machines, mobile setups |
| **Hybrid** | Acts as both server and client | Advanced: peer-to-peer networks |

---

## Fleet Monitor Architecture

Fleet Monitor provides:
- **Machine registration** - Each machine reports identity and status
- **Agent status tracking** - Monitor which agents are active on which machines
- **Kanban aggregation** - View all kanban boards across machines
- **Service health monitoring** - Track LCARS and other services
- **Cross-machine coordination** - Coordinate parallel development

### Components

```
┌─────────────────┐         ┌─────────────────┐
│  Machine A      │         │  Machine B      │
│  (Server)       │◄────────┤  (Client)       │
│                 │  HTTP   │                 │
│  Fleet Monitor  │         │  Fleet Client   │
│  :3000          │────────►│  Reports Status │
│                 │         │                 │
│  LCARS :8082    │         │  LCARS :8082    │
│  Kanban Boards  │         │  Kanban Boards  │
└─────────────────┘         └─────────────────┘
         │                           │
         │       Tailscale VPN       │
         └───────────────────────────┘
              (Secure tunnel)
```

### Data Flow

1. **Client machines** periodically POST status to server
2. **Server** aggregates data from all clients
3. **Dashboard** displays unified view of entire fleet
4. **Kanban sync** (optional) keeps boards in sync across machines

---

## Tailscale Setup

Tailscale provides secure networking between machines without port forwarding or firewall configuration.

### Why Tailscale?

- **Zero-config VPN** - Machines connect automatically
- **No port forwarding** - Works behind NATs and firewalls
- **Encrypted** - All traffic is encrypted end-to-end
- **Fast** - Direct peer-to-peer connections when possible
- **Funnel support** - Expose services with HTTPS

### Installing Tailscale

#### Step 1: Install on All Machines

```bash
# Install Tailscale
brew install --cask tailscale

# Or download from: https://tailscale.com/download
```

#### Step 2: Create Tailscale Account

1. Sign up at [tailscale.com](https://tailscale.com)
2. Choose authentication provider (Google, GitHub, Microsoft, etc.)

#### Step 3: Connect Each Machine

On **each machine** you want to connect:

```bash
# Open Tailscale app (appears in menu bar)
# Click "Connect" or "Log in"
# Authenticate via browser

# Verify connection
tailscale status
```

**Example output:**
```
100.64.0.1    macbook-pro-office    user@    macOS   active
100.64.0.2    macbook-air-home      user@    macOS   active
100.64.0.3    mac-mini-server       user@    macOS   active
```

#### Step 4: Enable MagicDNS

MagicDNS allows using machine names instead of IP addresses.

1. Open Tailscale admin console: https://login.tailscale.com/admin
2. Navigate to **DNS** settings
3. Enable **MagicDNS**

Now you can access machines by name:
```bash
# Instead of: http://100.64.0.1:3000
# Use: http://macbook-pro-office:3000
```

#### Step 5: Enable Funnel (Optional)

Funnel exposes services with HTTPS certificates.

```bash
# Enable Funnel for Fleet Monitor
tailscale funnel 3000

# Enable Funnel for LCARS
tailscale funnel 8082
```

**Note:** Funnel requires admin approval in Tailscale console for some plans.

---

## Server Configuration

The **server machine** hosts the Fleet Monitor service and acts as the central coordinator.

### Prerequisites

- Tailscale installed and connected
- AITeamForge installed
- Machine that's usually running (main workstation or dedicated server)

### Setup Steps

#### Step 1: Run Setup Wizard

```bash
aiteamforge setup
```

During feature selection:
- **Fleet Monitor:** Yes
- **Fleet Monitor Mode:** Server
- **Fleet Monitor Port:** 3000 (default)

#### Step 2: Configure Machine Identity

When prompted:
- **Machine name:** Choose descriptive name (e.g., "macbook-pro-office")
- **User display name:** Your name

#### Step 3: Verify Configuration

```bash
# Check Fleet Monitor config
cat ~/aiteamforge/fleet-monitor/config.json
```

**Example server config:**
```json
{
  "mode": "server",
  "port": 3000,
  "hostname": "0.0.0.0",
  "machines": [],
  "sync": {
    "kanban": false,
    "interval": 60
  }
}
```

#### Step 4: Start Fleet Monitor

```bash
# Start Fleet Monitor
aiteamforge start fleet-monitor

# Verify it's running
curl http://localhost:3000/api/health
# Expected: {"status":"ok","version":"1.0.0"}
```

#### Step 5: Access Dashboard

Open in browser:
```
http://localhost:3000
```

**Via Tailscale from other machines:**
```
http://macbook-pro-office:3000
```

**Via Tailscale Funnel (if enabled):**
```
https://macbook-pro-office.TAILNET.ts.net:3000
```

### Server Management

```bash
# Check Fleet Monitor status
aiteamforge status

# View Fleet Monitor logs
tail -f ~/aiteamforge/logs/fleet-monitor.log

# Restart Fleet Monitor
aiteamforge restart fleet-monitor

# Stop Fleet Monitor
aiteamforge stop fleet-monitor
```

---

## Client Configuration

**Client machines** report their status to the server but don't host the Fleet Monitor dashboard.

### Prerequisites

- Tailscale installed and connected
- AITeamForge installed
- Know server machine's Tailscale hostname or IP

### Setup Steps

#### Step 1: Run Setup Wizard

```bash
aiteamforge setup
```

During feature selection:
- **Fleet Monitor:** Yes
- **Fleet Monitor Mode:** Client
- **Server Address:** Enter server's Tailscale hostname (e.g., "macbook-pro-office:3000")

#### Step 2: Configure Machine Identity

When prompted:
- **Machine name:** Choose descriptive name (e.g., "macbook-air-home")
- **User display name:** Your name

#### Step 3: Verify Configuration

```bash
# Check Fleet Monitor config
cat ~/aiteamforge/fleet-monitor/config.json
```

**Example client config:**
```json
{
  "mode": "client",
  "server": "http://macbook-pro-office:3000",
  "machine": {
    "name": "macbook-air-home",
    "user": "John Doe",
    "hostname": "macbook-air-home.local"
  },
  "report_interval": 60
}
```

#### Step 4: Start Fleet Monitor Client

```bash
# Start Fleet Monitor client
aiteamforge start fleet-monitor

# Verify it's reporting
curl http://localhost:3000/api/status
```

#### Step 5: Verify on Server

On the **server machine**, check if client is registered:

```bash
# Via API
curl http://localhost:3000/api/machines

# Via dashboard
open http://localhost:3000
# You should see the client machine listed
```

### Client Management

```bash
# Check client status
aiteamforge status

# View client logs
tail -f ~/aiteamforge/logs/fleet-monitor-client.log

# Restart client
aiteamforge restart fleet-monitor

# Stop client
aiteamforge stop fleet-monitor
```

---

## Hybrid Configuration

**Hybrid mode** allows a machine to act as both server (hosting dashboard) and client (reporting to another server). This creates peer-to-peer networks.

### Use Case

- Multiple developers each running their own server
- Mutual monitoring across team
- Decentralized architecture

### Setup

```bash
aiteamforge setup
```

During feature selection:
- **Fleet Monitor:** Yes
- **Fleet Monitor Mode:** Hybrid
- **Server Port:** 3000
- **Report to Server:** Enter another server's address

**Example hybrid config:**
```json
{
  "mode": "hybrid",
  "server": {
    "port": 3000,
    "hostname": "0.0.0.0"
  },
  "client": {
    "report_to": "http://other-machine:3000",
    "interval": 60
  }
}
```

---

## Service Discovery

Fleet Monitor uses HTTP-based service discovery.

### How It Works

1. **Client registration** - Each client POSTs to `/api/register` on server
2. **Heartbeat** - Clients POST to `/api/heartbeat` every 60 seconds
3. **Machine list** - Server maintains list at `/api/machines`
4. **Status aggregation** - Server queries clients for status via `/api/status`

### Discovery Endpoints

```bash
# List all registered machines
curl http://server:3000/api/machines

# Get specific machine status
curl http://server:3000/api/machines/macbook-air-home

# Get aggregated fleet status
curl http://server:3000/api/fleet/status
```

### Manual Registration

If auto-discovery fails, manually register client:

```bash
curl -X POST http://server:3000/api/register \
  -H "Content-Type: application/json" \
  -d '{
    "name": "macbook-air-home",
    "hostname": "macbook-air-home.local",
    "user": "John Doe",
    "tailscale_ip": "100.64.0.2"
  }'
```

---

## Shared Kanban State

Fleet Monitor can optionally sync kanban boards across machines.

### Enabling Kanban Sync

#### On Server

Edit `~/aiteamforge/fleet-monitor/config.json`:

```json
{
  "sync": {
    "kanban": true,
    "interval": 300,
    "strategy": "server_primary"
  }
}
```

**Sync strategies:**
- `server_primary` - Server is source of truth, clients pull from server
- `last_write_wins` - Most recent change wins across all machines
- `manual` - No auto-sync, manual sync only

#### On Clients

Edit `~/aiteamforge/fleet-monitor/config.json`:

```json
{
  "sync": {
    "kanban": true,
    "pull_interval": 300,
    "push_on_change": true
  }
}
```

### Sync Workflow

**Server Primary Mode:**
1. Server's kanban boards are authoritative
2. Clients pull updates every 5 minutes
3. Client changes are pushed to server immediately
4. Server merges changes and broadcasts to other clients

**Conflict Resolution:**
- Same item modified on multiple machines → last write wins
- Items deleted on one machine → tombstone marker prevents resurrection
- Sync errors are logged but don't block local work

### Manual Sync

```bash
# Pull latest from server
kb-sync pull

# Push local changes to server
kb-sync push

# Full sync (push then pull)
kb-sync
```

### Viewing Sync Status

```bash
# Check sync status
kb-sync status

# View sync log
tail -f ~/aiteamforge/logs/kanban-sync.log
```

---

## Monitoring Agents

Fleet Monitor tracks active Claude Code agents across all machines.

### Agent Status Display

On Fleet Monitor dashboard:
- **Active agents** - Which agents are currently running
- **Machine location** - Which machine each agent is on
- **Current work** - Which kanban items agents are working on
- **Session duration** - How long each agent has been active

### Agent API

```bash
# List all active agents across fleet
curl http://server:3000/api/agents

# Get agents on specific machine
curl http://server:3000/api/machines/macbook-air-home/agents

# Get agent work history
curl http://server:3000/api/agents/ios-picard/history
```

### Agent Coordination

Fleet Monitor helps avoid conflicts:
- **Work item locking** - Alerts if multiple agents work on same item
- **Resource awareness** - Shows which machines are under load
- **Session tracking** - Historical record of agent activity

---

## Troubleshooting Network Issues

### Common Issues

#### Issue: Client Can't Connect to Server

**Symptoms:** Client shows "Connection refused" or "Network unreachable"

**Diagnosis:**
```bash
# On client, test connection to server
ping macbook-pro-office

# Test Fleet Monitor port
nc -zv macbook-pro-office 3000

# Check Tailscale status
tailscale status
```

**Solutions:**

1. **Verify Tailscale is connected on both machines:**
   ```bash
   tailscale status
   # Should show both machines as "active"
   ```

2. **Verify server is running:**
   ```bash
   # On server
   curl http://localhost:3000/api/health
   ```

3. **Check firewall (macOS):**
   ```bash
   # Allow incoming connections for Fleet Monitor
   # System Settings → Network → Firewall → Allow Fleet Monitor
   ```

4. **Use IP address instead of hostname:**
   ```bash
   # Find server's Tailscale IP
   tailscale status | grep macbook-pro-office

   # Update client config with IP
   # Edit ~/aiteamforge/fleet-monitor/config.json
   # Change "server" to use IP: "http://100.64.0.1:3000"
   ```

#### Issue: Intermittent Disconnections

**Symptoms:** Client connects sometimes but drops frequently

**Diagnosis:**
```bash
# Check Tailscale connection quality
tailscale ping macbook-pro-office

# View Fleet Monitor logs
tail -f ~/aiteamforge/logs/fleet-monitor-client.log
```

**Solutions:**

1. **Increase heartbeat interval:**
   ```json
   {
     "report_interval": 120
   }
   ```

2. **Check for network issues:**
   ```bash
   tailscale status --active
   ```

3. **Use DERP relay (if direct connection fails):**
   Tailscale automatically uses relay servers if P2P fails.

#### Issue: Kanban Sync Conflicts

**Symptoms:** Changes on one machine don't appear on others

**Diagnosis:**
```bash
# Check sync status
kb-sync status

# View sync log
tail -f ~/aiteamforge/logs/kanban-sync.log
```

**Solutions:**

1. **Verify sync is enabled:**
   ```bash
   cat ~/aiteamforge/fleet-monitor/config.json | jq .sync
   ```

2. **Manually trigger sync:**
   ```bash
   kb-sync
   ```

3. **Check for conflicts:**
   ```bash
   kb-sync conflicts
   ```

4. **Resolve conflicts manually:**
   ```bash
   # Pull latest from server (overwrites local)
   kb-sync pull --force

   # Or: keep local, push to server
   kb-sync push --force
   ```

#### Issue: Port Already in Use

**Symptoms:** Fleet Monitor won't start, "Port 3000 already in use"

**Diagnosis:**
```bash
# Find what's using the port
lsof -i :3000
```

**Solutions:**

1. **Kill the process:**
   ```bash
   kill -9 <PID>
   ```

2. **Change Fleet Monitor port:**
   ```bash
   # Edit ~/aiteamforge/fleet-monitor/config.json
   # Change "port" to different value (e.g., 3001)

   # Restart
   aiteamforge restart fleet-monitor
   ```

3. **Update clients to use new port:**
   ```bash
   # On each client, edit config.json
   # Change "server" URL to include new port
   ```

### Network Diagnostics

```bash
# Comprehensive network test
aiteamforge doctor --check network

# Test connectivity to all registered machines
fleet-monitor-test-connections

# View network topology
tailscale status --json | jq .
```

### Getting Help

If network issues persist:

1. **Collect diagnostic info:**
   ```bash
   aiteamforge doctor --verbose > ~/diagnostic-report.txt
   tailscale status >> ~/diagnostic-report.txt
   ```

2. **Check Fleet Monitor logs:**
   ```bash
   tail -100 ~/aiteamforge/logs/fleet-monitor.log
   ```

3. **Check Tailscale logs:**
   ```bash
   tail -100 /Library/Logs/Tailscale/tailscaled.log
   ```

---

## Advanced Configuration

### Custom Network Topology

For complex setups (multiple offices, VPNs, etc.), see [Advanced Fleet Monitor Configuration](fleet-monitor/ADVANCED_CONFIG.md).

### Security Considerations

- **Tailscale authentication** - Only machines in your Tailnet can connect
- **API keys** - Optional: require API keys for Fleet Monitor access
- **HTTPS** - Use Tailscale Funnel for HTTPS with automatic certificates
- **Access control** - Limit which machines can access server

### Performance Tuning

```json
{
  "report_interval": 30,
  "cache_ttl": 300,
  "max_clients": 10,
  "compression": true
}
```

---

## Summary

Multi-machine setup enables:
- **Distributed development** across multiple Macs
- **Seamless context switching** between office and home
- **Team collaboration** with shared kanban state
- **Fleet monitoring** of all development machines

**Key Components:**
- **Tailscale** - Secure networking
- **Fleet Monitor** - Central coordination
- **Kanban sync** - Shared task state
- **Agent tracking** - Cross-machine agent monitoring

**Next Steps:**
- Continue to [Troubleshooting](TROUBLESHOOTING.md) for common issues
- Review [Architecture](ARCHITECTURE.md) to understand the system design
- Check [User Guide](USER_GUIDE.md) for day-to-day usage
