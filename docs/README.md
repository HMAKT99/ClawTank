# ClawTank documentation

## Using ClawTank
| Guide | What it covers |
|---|---|
| [README](../README.md) | Install, connect from each client, FAQ, troubleshooting |
| [Remote access](remote-access.md) | Connecting from outside your network with Tailscale, and waking a sleeping Mac |
| [Agent API and MCP](agent-api.md) | Letting local AI agents see and drive the Mac: setup, MCP tools, REST API, security model |
| [Beta testing guide](beta-testing.md) | A test script for 0.9 beta testers, and how to report results |

## How it works
| Document | What it covers |
|---|---|
| [Architecture](architecture.md) | The Rust core and the Swift host, data paths, security model, repository map |
| [Design decisions (ADRs)](decisions.md) | Every significant choice, with its context and consequences |
| [Research: IronRDP](research/ironrdp.md) | IronRDP server capabilities and gaps |
| [Research: virtual displays](research/virtual-display.md) | The `CGVirtualDisplay` spike and its findings |

## Working on ClawTank
| Document | What it covers |
|---|---|
| [Contributing](../CONTRIBUTING.md) | Development setup, conventions, the clean-room rule, pull requests |
| [Testing](testing.md) | Automated coverage, live measurements, and the manual checklist with results |
| [Releasing](releasing.md) | `make release`, Developer ID signing and notarization, updates |
| [Security policy](../SECURITY.md) | How to report a vulnerability |
| [Phase plans](plans/README.md) | Historical working plans from development (not kept up to date) |
