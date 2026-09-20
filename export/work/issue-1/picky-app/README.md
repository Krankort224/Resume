# Windows application

This directory owns the compiled WPF presentation layer and user intent.

Invariants:

- the GUI remains non-elevated during ordinary use;
- it does not independently own sing-box, TUN, DNS, WFP, transport health or cleanup;
- Connect/Disconnect are dispatched through the accepted Windows controller boundary;
- normal product execution uses the canonical Windows bundle rather than repository/component fallback paths.

Canonical details:

- [Windows architecture](../../../knowledge/WINDOWS_ARCHITECTURE.md)
- [cross-platform lifecycle/ownership](../../../knowledge/ARCHITECTURE.md)
- [Windows coexistence](../../../knowledge/WINDOWS_NETWORK_COEXISTENCE.md)
- [development/build environment](../../../knowledge/DEVELOPMENT_ENVIRONMENT.md)
