# Repository instructions

- Treat CCS projects and emulator operations as hardware-affecting actions.
- Never report success unless `RESULT: OK` was actually emitted and the process
  exit code is zero.
- Setup/install helpers must aggregate failures and exit non-zero when a
  required step fails.
- Keep PowerShell scripts at `#requires -Version 7.0`.
- Before changing setup logic, run `tests/test_setup_failure.ps1`.
