---
name: open-localhost-app
description: Open the integrated browser on https://localhost:7443 for the
   local app/proxy entrypoint and return immediately.
   Trigger when asked to open localhost:7443 or open the local app container.
---

# Open Localhost App Page

Use this skill for opening the local HTTPS app entrypoint in development.

## Workflow

1. Open the page in the integrated browser with:
   `open_browser_page(url="https://localhost:7443")`.
2. Return immediately after the browser window/tab opens.
3. Do not inspect, click, or automate certificate warnings or trust controls.
4. Do not navigate further.
5. If certificate trust is already in place, the browser may redirect to
   `https://localhost:7443/app` automatically.
6. If certificate trust is not in place, the browser may show certificate
   controls; user action is required.

## Repository Context

- Browser integration setting guidance:
  [../../copilot-instructions.md](../../copilot-instructions.md)
- Proxy certificate file location:
  [../../../docker/proxy/conf/certificates/README.md](../../../docker/proxy/conf/certificates/README.md)
- WSL/network notes for port 7443:
  [../../../README.connect-to-WSL.ANGULARJS.md](../../../README.connect-to-WSL.ANGULARJS.md)
