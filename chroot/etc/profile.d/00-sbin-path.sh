# Put /usr/sbin and /sbin on PATH for all login users so admin tools
# are callable as bare commands (dhcpcd, dhclient, ifconfig, route, arp, ...).
# Debian's default PATH for non-root users lacks the sbin directories.
for _sbin in /usr/sbin /sbin; do
    case ":$PATH:" in
        *:"$_sbin":*) ;;
        *) PATH="$PATH:$_sbin" ;;
    esac
done
export PATH