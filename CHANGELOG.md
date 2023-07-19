# RIPEDA's Privileges Client Changelog

## 1.5.9
- Move timeout to Menubar item
  - Displays time remaining while admin
  - Supersedes Watchdog timer and drops Python dependency in app

## 1.5.8
- Implement new Menubar item for managing Privileges
  - Accompanied by Launch Agent
  - Supersedes dock icon logic
- Delete Install Package Receipts during uninstall
- Demote user on login

## 1.5.7
- Resolve RELEASE build support
- Add Watchdog timer configuration
  - Through `TimerLength` key in `com.ripeda.privileges` Profile

## 1.5.6
- Add support for Universal2 binaries on DEBUG builds
- Resolve defaults not being read by app

## 1.5.5
- Changes org references to RIPEDA (from SAPCorp)
- Add sample profile
- Add code signing to app and packages
- Add app to current user's dock
  - Thanks to LGharrison

## 1.5.4
- Implement support for HTTP/HTTPS logging server
- Implement JSON payload for logs
- Publish host information in logs
  - ex. serial, client MDM name, etc.
- Implement LaunchAgent to demote after certain period of time