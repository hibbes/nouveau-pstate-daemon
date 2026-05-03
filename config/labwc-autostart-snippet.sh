# Drop this line into your ~/.config/labwc/autostart to launch the
# nouveau-pstate swayidle bridge alongside the rest of your session.
#
# The bridge requires:
#   - /usr/local/bin/nv-pstate installed
#   - /etc/sudoers.d/nouveau-pstate installed
#   - your user in group 'nouveau-pstate'
#   - swayidle on $PATH

/usr/local/bin/nouveau-pstate-swayidle &
