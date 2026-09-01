# Local Development Setup

## Running on Physical Devices

By default, `AppEnvironment.current` uses `127.0.0.1` which works for iOS Simulator. 

When testing on a **physical device**, you need to configure the local backend IP address.

### Option 1: Temporary Override (Recommended for Testing)

Edit `Shared/FluentWorkCore/AppEnvironment.swift`:

```swift
#if DEBUG
// Change from:
public static let current: AppEnvironment = .local

// To:
public static let current: AppEnvironment = .local(host: "YOUR_LOCAL_IP")
// Example: .local(host: "192.168.2.15")
#else
// ...
#endif
```

### Option 2: Runtime Configuration (Future Enhancement)

For a more flexible solution, consider:
- Environment variable: `LOCAL_BACKEND_HOST`
- Xcode scheme configuration
- Launch arguments: `-local-host 192.168.2.15`

### Finding Your Local IP Address

**macOS:**
```bash
# Wi-Fi
ipconfig getifaddr en0

# Ethernet
ipconfig getifaddr en1
```

**Alternative (all interfaces):**
```bash
ifconfig | grep "inet " | grep -v 127.0.0.1
```

### Backend Server Requirements

Ensure your local backend server:
1. Is running on the specified ports (8080 for HTTP, 8081 for WebSocket)
2. Is accessible from the device's network
3. Allows connections from your device's IP

### Network Troubleshooting

**Device and Mac must be on the same network:**
- Connect both to the same Wi-Fi network
- Or use USB network tethering

**Firewall settings:**
- Allow incoming connections to ports 8080 and 8081
- macOS: System Settings → Network → Firewall

**Test connectivity:**
```bash
# On device (using Safari or a browser)
http://YOUR_LOCAL_IP:8080/api/v1/health
```

### CI/CD Considerations

The default `127.0.0.1` ensures:
- Tests pass in CI without configuration
- Simulator development works out of the box
- No accidental commits of personal IP addresses

**Never commit your personal IP to version control.** Use the override only locally.
