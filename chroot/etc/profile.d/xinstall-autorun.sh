# Auto-start the xinstall menu on interactive console logins for root/x3m.
# Skip in scripts, over SSH, and non-interactive sessions.
# Disable per session:   export XINSTALL_SKIP=1
# Disable permanently:   touch /etc/xinstall-no-autorun
if [ ! -t 0 ] || [ -n "$SSH_CONNECTION" ] || [ -n "$XINSTALL_SKIP" ] \
    || [ -f /etc/xinstall-no-autorun ]; then
    return 0
fi
command -v xinstall >/dev/null 2>&1 || return 0
case "$(id -un)" in
    root|x3m) xinstall || true ;;
esac
return 0