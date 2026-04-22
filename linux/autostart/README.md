# Autostart Overrides

These files disable useless/privacy-invasive autostart entries at login.
Place in ~/.config/autostart/ to override system-wide entries in /etc/xdg/autostart/.

- spice-vdagent.desktop  — disables VM guest agent (useless on bare metal)
- orca-autostart.desktop — disables screen reader auto-launch
- geoclue-demo-agent.desktop — disables location demo agent (privacy risk)

**Restore:**
```bash
cp linux/autostart/*.desktop ~/.config/autostart/
```
