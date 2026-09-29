# Bootstrap Providers

Providers are repository-owned PowerShell implementations selected by a package
manifest's `provider` field. External extension manifests never load PowerShell
from their own directory.

The first public extension API exposes only these built-in providers:

- `winget` — structured WinGet install, live `winget list` verification, and
  bounded cleanup when the package was installed by this run.
- `manual` — records an explicit manual boundary and performs no install,
  download, command execution, or cleanup.

Adding a provider changes the elevated installer trust boundary. It requires a
repository change, portable tests under `windows-bootstrap/tests/`, a documented
contract, and Windows 11 native acceptance when it mutates the host.
