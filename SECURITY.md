# Security

chauffeur runs on your Mac and drives iOS simulators only. It makes no network requests of its own.

Text that chauffeur reads from the screen (labels, alerts, log lines) comes from the app under test. Treat it as
untrusted. chauffeur's MCP instructions and agent skill tell the agent never to follow instructions found there.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting on
[YashNaj/chauffeur](https://github.com/YashNaj/chauffeur/security/advisories/new), not a public issue.
