```mermaid
sequenceDiagram
    participant User
    participant App
    participant Bootstrap
    participant TokenStore
    participant SessionAPI
    participant Backend

    User->>App: Launch App
    App->>Bootstrap: .lifecycle(.appLaunched)
    Bootstrap->>Bootstrap: loadBootstrap()
    
    Note over Bootstrap: ensureGuestToken()
    Bootstrap->>TokenStore: accessToken()
    
    alt Token exists
        TokenStore-->>Bootstrap: "existing_token_123"
        Note over Bootstrap: Skip guest issuance
    else No token
        TokenStore-->>Bootstrap: nil
        Bootstrap->>TokenStore: deviceID()
        
        alt Device ID exists
            TokenStore-->>Bootstrap: "device_abc"
        else Generate new
            TokenStore->>TokenStore: Generate UUID
            TokenStore->>TokenStore: Save to keychain
            TokenStore-->>Bootstrap: "device_xyz"
        end
        
        Bootstrap->>SessionAPI: issueGuest(deviceID)
        SessionAPI->>Backend: POST /auth/guest
        Backend-->>SessionAPI: TokenResponse
        SessionAPI-->>Bootstrap: TokenResponse
        
        Bootstrap->>TokenStore: save(tokens, deviceID)
        TokenStore->>TokenStore: Write to keychain
    end
    
    Note over Bootstrap: Load feature flags
    Bootstrap->>Bootstrap: resolver.refresh()
    Bootstrap-->>App: BootstrapSnapshot
    
    App->>App: .bootstrapSucceeded()
    App->>User: Show UI (authenticated)
```

## State Machine

```
┌─────────────┐
│ App Launch  │
└──────┬──────┘
       │
       v
┌─────────────────┐
│ Check Keychain  │
└──────┬──────────┘
       │
       ├─── Token exists ───┐
       │                    │
       └─── No token        │
              │             │
              v             │
       ┌──────────────┐     │
       │ Get/Generate │     │
       │  Device ID   │     │
       └──────┬───────┘     │
              │             │
              v             │
       ┌──────────────┐     │
       │ Call Backend │     │
       │ /auth/guest  │     │
       └──────┬───────┘     │
              │             │
              v             │
       ┌──────────────┐     │
       │ Save Token   │     │
       │ to Keychain  │     │
       └──────┬───────┘     │
              │             │
              v             v
       ┌──────────────────────┐
       │ Load Feature Flags   │
       └──────────┬───────────┘
                  │
                  v
       ┌──────────────────────┐
       │ Bootstrap Complete   │
       │ App Ready            │
       └──────────────────────┘
```
