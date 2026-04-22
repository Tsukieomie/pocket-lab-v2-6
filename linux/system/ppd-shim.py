#!/usr/bin/env python3
import configparser
import os
import signal
import subprocess
import sys
from pathlib import Path

from gi.repository import GLib
from pydbus import SystemBus
from pydbus.generic import signal as dbus_signal

BUS_NAME = "org.freedesktop.UPower.PowerProfiles"
OBJECT_PATH = "/org/freedesktop/UPower/PowerProfiles"
LEGACY_BUS_NAME = "net.hadess.PowerProfiles"
LEGACY_OBJECT_PATH = "/net/hadess/PowerProfiles"

SCRIPT_PATH = "/usr/local/libexec/legacy-power-mode.sh"
STATE_DIR = Path("/var/lib/power-profiles-daemon")
STATE_FILE = STATE_DIR / "state.ini"

INTROSPECTION_XML = """<?xml version="1.0" encoding="UTF-8"?>
<node>
  <interface name="org.freedesktop.UPower.PowerProfiles">
    <method name="HoldProfile">
      <arg name="profile" type="s" direction="in"/>
      <arg name="reason" type="s" direction="in"/>
      <arg name="application_id" type="s" direction="in"/>
      <arg name="cookie" type="u" direction="out"/>
    </method>
    <method name="ReleaseProfile">
      <arg name="cookie" type="u" direction="in"/>
    </method>
    <method name="SetActionEnabled">
      <arg name="action" type="s" direction="in"/>
      <arg name="enabled" type="b" direction="in"/>
    </method>
    <property name="ActiveProfile" type="s" access="readwrite"/>
    <property name="ActiveProfileHolds" type="aa{sv}" access="read"/>
    <property name="Actions" type="as" access="read"/>
    <property name="ActionsInfo" type="aa{sv}" access="read"/>
    <property name="BatteryAware" type="b" access="readwrite"/>
    <property name="PerformanceDegraded" type="s" access="read"/>
    <property name="PerformanceInhibited" type="s" access="read"/>
    <property name="Profiles" type="aa{sv}" access="read"/>
    <property name="Version" type="s" access="read"/>
    <signal name="ProfileReleased">
      <arg name="cookie" type="u"/>
    </signal>
  </interface>
  <interface name="net.hadess.PowerProfiles">
    <method name="HoldProfile">
      <arg name="profile" type="s" direction="in"/>
      <arg name="reason" type="s" direction="in"/>
      <arg name="application_id" type="s" direction="in"/>
      <arg name="cookie" type="u" direction="out"/>
    </method>
    <method name="ReleaseProfile">
      <arg name="cookie" type="u" direction="in"/>
    </method>
    <method name="SetActionEnabled">
      <arg name="action" type="s" direction="in"/>
      <arg name="enabled" type="b" direction="in"/>
    </method>
    <property name="ActiveProfile" type="s" access="readwrite"/>
    <property name="ActiveProfileHolds" type="aa{sv}" access="read"/>
    <property name="Actions" type="as" access="read"/>
    <property name="ActionsInfo" type="aa{sv}" access="read"/>
    <property name="BatteryAware" type="b" access="readwrite"/>
    <property name="PerformanceDegraded" type="s" access="read"/>
    <property name="PerformanceInhibited" type="s" access="read"/>
    <property name="Profiles" type="aa{sv}" access="read"/>
    <property name="Version" type="s" access="read"/>
    <signal name="ProfileReleased">
      <arg name="cookie" type="u"/>
    </signal>
  </interface>
</node>
"""


class PowerProfilesShim:
    dbus = INTROSPECTION_XML

    PropertiesChanged = dbus_signal()
    ProfileReleased = dbus_signal()

    def __init__(self):
        self._active_profile = "balanced"
        self._battery_aware = True
        self._holds = {}
        self._next_cookie = 1
        self._bus = SystemBus()
        self._loop = GLib.MainLoop()
        self._load_state()

    def _load_state(self):
        if not STATE_FILE.exists():
            return
        parser = configparser.ConfigParser()
        parser.read(STATE_FILE)
        if parser.has_section("State"):
            self._active_profile = parser.get("State", "ActiveProfile", fallback=self._active_profile)
            self._battery_aware = parser.getboolean("State", "BatteryAware", fallback=self._battery_aware)

    def _save_state(self):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        parser = configparser.ConfigParser()
        parser["State"] = {
            "ActiveProfile": self._active_profile,
            "BatteryAware": "true" if self._battery_aware else "false",
        }
        with STATE_FILE.open("w") as f:
            parser.write(f)

    def _run_mode(self, profile):
        subprocess.run([SCRIPT_PATH, profile], check=True)

    def _emit_properties_changed(self, changed):
        self.PropertiesChanged("org.freedesktop.UPower.PowerProfiles", changed, [])
        self.PropertiesChanged("net.hadess.PowerProfiles", changed, [])

    def HoldProfile(self, profile, reason, application_id):
        if profile not in ("performance", "power-saver"):
            raise Exception("Only profiles 'performance' and 'power-saver' can be held")
        cookie = self._next_cookie
        self._next_cookie += 1
        self._holds[cookie] = {
            "Profile": profile,
            "Reason": reason,
            "ApplicationId": application_id,
        }
        self.ActiveProfile = profile
        return cookie

    def ReleaseProfile(self, cookie):
        if cookie not in self._holds:
            return
        del self._holds[cookie]
        self.ProfileReleased(cookie)
        if self._holds:
            held_profile = next(iter(self._holds.values()))["Profile"]
            self.ActiveProfile = held_profile

    def SetActionEnabled(self, action, enabled):
        return

    @property
    def ActiveProfile(self):
        return self._active_profile

    @ActiveProfile.setter
    def ActiveProfile(self, value):
        if value not in ("power-saver", "balanced", "performance"):
            raise Exception(f"Unsupported profile: {value}")
        self._run_mode(value)
        self._active_profile = value
        self._save_state()
        self._emit_properties_changed({"ActiveProfile": self._active_profile})

    @property
    def ActiveProfileHolds(self):
        return [
            {
                "Profile": GLib.Variant("s", hold["Profile"]),
                "Reason": GLib.Variant("s", hold["Reason"]),
                "ApplicationId": GLib.Variant("s", hold["ApplicationId"]),
            }
            for hold in self._holds.values()
        ]

    @property
    def Actions(self):
        return []

    @property
    def ActionsInfo(self):
        return []

    @property
    def BatteryAware(self):
        return self._battery_aware

    @BatteryAware.setter
    def BatteryAware(self, value):
        self._battery_aware = bool(value)
        self._save_state()
        self._emit_properties_changed({"BatteryAware": self._battery_aware})

    @property
    def PerformanceDegraded(self):
        return ""

    @property
    def PerformanceInhibited(self):
        return ""

    @property
    def Profiles(self):
        return [
            {
                "Profile": GLib.Variant("s", "power-saver"),
                "PlatformDriver": GLib.Variant("s", "shim"),
                "Driver": GLib.Variant("s", "shim"),
            },
            {
                "Profile": GLib.Variant("s", "balanced"),
                "PlatformDriver": GLib.Variant("s", "shim"),
                "Driver": GLib.Variant("s", "shim"),
            },
            {
                "Profile": GLib.Variant("s", "performance"),
                "PlatformDriver": GLib.Variant("s", "shim"),
                "Driver": GLib.Variant("s", "shim"),
            },
        ]

    @property
    def Version(self):
        return "0.30-shim"

    def run(self):
        self._bus.publish(BUS_NAME, (OBJECT_PATH, self))
        self._bus.publish(LEGACY_BUS_NAME, (LEGACY_OBJECT_PATH, self))

        def _shutdown(*_args):
            self._loop.quit()

        signal.signal(signal.SIGTERM, _shutdown)
        signal.signal(signal.SIGINT, _shutdown)
        self._loop.run()


if __name__ == "__main__":
    if os.geteuid() != 0:
        print("ppd-shim.py must run as root", file=sys.stderr)
        sys.exit(1)
    shim = PowerProfilesShim()
    shim.run()
