"""
This script will be fired up at Launch Time as a LaunchDaemon.
Every minute, we'll check the current status of the user's privileges.
If they're admin, start a count down timer to demote them.
If they manually demote themselves, stop the timer.
"""

import subprocess
import threading
import enum
import time
from pathlib import Path

CLI_PATH: str = "/Applications/Privileges.app/Contents/Resources/PrivilegesCLI"
TIMER_LENGTH: float = 15.0
GLOBAL_TIMER: threading.Timer = None

class PrivilegesMode(enum.Enum):
    ADMIN    = "admin"
    STANDARD = "standard"
    UNKNOWN  = "unknown"


class PrivilegesWatchdog:

    def __init__(self) -> None:
        print("Privileges Watchdog started")

        if not Path(CLI_PATH).exists():
            raise Exception(f"Privileges CLI not found at {CLI_PATH}")

        self._start()


    def _start(self) -> None:
        while True:
            self._check_privileges()
            time.sleep(60.0)


    def _check_privileges(self) -> None:
        """
        Check the current privileges mode
        """
        current_privileges = self._get_current_privileges()

        print(f"Current privileges: {current_privileges}")

        if current_privileges == PrivilegesMode.ADMIN:
            print("User is admin, starting timer")
            self._start_timer()
            return

        global GLOBAL_TIMER
        if GLOBAL_TIMER is not None:
            print("User is not admin, stopping timer")
            GLOBAL_TIMER.cancel()
            GLOBAL_TIMER = None
            return

        print("No timer running")

    def _get_current_privileges(self) -> str:
        """
        Check if admin or standard user

        For some reason PrivilegesCLI outputs to STDERR...
        """
        result = subprocess.run([CLI_PATH, "--status"], capture_output=True)
        if result.returncode != 0:
            return PrivilegesMode.UNKNOWN

        return PrivilegesMode.ADMIN if "has admin rights" in result.stderr.decode("utf-8") else PrivilegesMode.STANDARD


    def _demote_user(self) -> None:
        """
        Demote the user
        """
        print("Demoting user")
        subprocess.run([CLI_PATH, "--remove"])

        global GLOBAL_TIMER
        GLOBAL_TIMER = None


    def _promote_user(self) -> None:
        """
        Promote the user

        This should never be called, but just in case...
        """
        print("Promoting user")
        subprocess.run([CLI_PATH, "--add"])


    def _start_timer(self) -> None:
        """
        Start the timer
        """
        global GLOBAL_TIMER
        GLOBAL_TIMER = threading.Timer(TIMER_LENGTH, self._demote_user)
        GLOBAL_TIMER.start()


if __name__ == "__main__":
    PrivilegesWatchdog()