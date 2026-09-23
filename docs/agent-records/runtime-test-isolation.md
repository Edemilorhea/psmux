# Runtime Test Isolation

## Always Use a Unique Namespace

Run runtime tests with a unique `-L` namespace. Use the same namespace for
every command in that test.

```powershell
./target/debug/psmux.exe -L <unique-test-namespace> new-session
./target/debug/psmux.exe -L <unique-test-namespace> list-windows
./target/debug/psmux.exe -L <unique-test-namespace> kill-server
```

Do not use the default namespace to test a newly built binary.

## Why This Is Required

psmux can keep a warm server running before a new session is requested. A new
session in the default namespace can claim that warm server. If an older binary
started the warm server, the new session continues to run the older server
code even when the command uses the newly built executable.

The result is an old server with a new session name. Recent code changes then
appear to have no effect.

A unique `-L` namespace prevents the test from claiming a warm server from the
default namespace. It starts an isolated server and session for the test.

## Cleanup

Clean up only the namespace created for the test:

```powershell
./target/debug/psmux.exe -L <unique-test-namespace> kill-server
```

Never use bare `psmux kill-server` for test cleanup.
