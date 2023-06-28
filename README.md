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
  * Currently set to 10 minutes
* Skip Codesign checks on DEBUG builds
  * Allows for testing of unsigned binaries

For documentation, please see the original repository:

* [SAP/macOS-enterprise-privileges](https://www.github.com/SAP/macOS-enterprise-privileges)