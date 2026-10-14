# macOS Compatibility Matrix

| macOS Version | Architecture | Status | Notes |
| :--- | :--- | :--- | :--- |
| **macOS 15 (Sequoia)** | Apple Silicon (M1/M2/M3/M4) | **Tier 1 — Full Support** | Validated on modern arm64 architecture with zero SIP requirements. |
| **macOS 15 (Sequoia)** | Intel (x86_64) | **Supported** | Compatible via Universal Binary or native x86_64 build. |
| **macOS 14 (Sonoma)** | Apple Silicon & Intel | **Tier 1 — Full Support** | Minimum deployment target. Full support for modern `SMAppService` and SwiftUI settings. |
| **macOS 13 (Ventura) & earlier** | Any | **Unsupported** | Deprecated APIs; lacks modern Swift 6 Sendable and ServiceManagement frameworks. |

---

## Hardware Compatibility

- **Apple Silicon M-Series (M1, M2, M3, M4)**: Native ARM64 execution with instantaneous layout calculations, sub-millisecond focus times, and minimal CPU overhead.
- **Multiple Displays**: Full support for mixed resolutions, retina and non-retina scaling, ProMotion 120Hz refresh rates, and hot-plugging.
