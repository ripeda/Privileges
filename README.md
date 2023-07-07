![PrivilegesBanner](readme_images/privileges_banner.gif)

# RIPEDA's Privileges Client

Forked variant of SAP's Privileges, with modifications for RIPEDA's workflow.

Changes include:

* Support for HTTP/HTTPS logging server
* Log messages through JSON payload
* Send additional host information (ex. Client name, serial number, etc.)
* LaunchAgent to demote after certain period of time
  * Designed to avoid users from abusing admin privileges indefinitely
    * Works-around `ReasonRequired` being unsupported with `DockToggleTimeout`
  * Defaults to 10min, configurable via `TimerLength` key in `com.ripeda.privileges` Profile
* Skip Codesign checks on DEBUG builds
  * Allows for testing of unsigned binaries

For documentation, please see the original repository:

* [SAP/macOS-enterprise-privileges](https://www.github.com/SAP/macOS-enterprise-privileges)

For logging, note that the Bundle ID has been adjusted (to avoid conflicts with the original Privileges client):
```sh
log stream --style syslog --predicate 'messageEvent CONTAINS "RIPEDA: "'
```