![PrivilegesBanner](readme_images/privileges_banner.gif)

# RIPEDA's Privileges

Forked variant of SAP's Privileges, with modifications for RIPEDA's workflow.

Changes include:

* Support for HTTP/HTTPS logging server
* Log messages through JSON payload
* Allow `ReasonRequired` and `DockToggleTimeout` to coexist
* Skip Codesign checks on DEBUG builds
  * Allows for testing of unsigned binaries

For documentation, please see the original repository:

* [SAP/macOS-enterprise-privileges](https://www.github.com/SAP/macOS-enterprise-privileges)