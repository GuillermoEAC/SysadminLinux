#!/usr/bin/env bash
set -euo pipefail

# =========================
# DHCP Server Automation (Linux - isc-dhcp-server)
# Idempotent install + interactive config + monitoring
# =========================

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Ejecuta como root (sudo)."
    exit 1
  fi
}

is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
  done
  return 0
}

ip_to_int() {
  local ip="$1"
  IFS='.' read -r a b c d <<< "$ip"
  echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

prompt_ipv4() {
  local label="$1"
  local val=""
  while true; do
    read -rp "$label: " val
    if is_valid_ipv4 "$val"; then
      echo "$val"
      return 0
    fi
    echo "  -> IPv4 inválida. Ejemplo: 192.168.100.1"
  done
}

prompt_nonempty() {
  local label="$1"
  local val=""
  while true; do
    read -rp "$label: " val
    if [[ -n "$val" ]]; then
      echo "$val"
      return 0
    fi
    echo "  -> No puede ir vacío."
  done
}

prompt_int() {
  local label="$1"
  local min="$2"
  local max="$3"
  local val=""
  while true; do
    read -rp "$label ($min-$max): " val
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max )); then
      echo "$val"
      return 0
    fi
    echo "  -> Número inválido."
  done
}

detect_default_iface() {
  # intenta obtener la interfaz de salida por default
  ip route 2>/dev/null | awk '/default/ {print $5; exit}'
}

install_idempotent() {
  if dpkg -s isc-dhcp-server >/dev/null 2>&1; then
    echo "[OK] isc-dhcp-server ya está instalado."
  else
    echo "[INFO] Instalando isc-dhcp-server (modo no interactivo)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y isc-dhcp-server
    echo "[OK] Instalación completa."
  fi
}

write_config() {
  local scope_name="$1"
  local subnet="$2"
  local netmask="$3"
  local range_start="$4"
  local range_end="$5"
  local lease_seconds="$6"
  local gateway="$7"
  local dns="$8"

  local conf="/etc/dhcp/dhcpd.conf"
  local backup="/etc/dhcp/dhcpd.conf.bak.$(date +%Y%m%d_%H%M%S)"

  if [[ -f "$conf" ]]; then
    cp "$conf" "$backup"
    echo "[INFO] Backup creado: $backup"
  fi

  cat > "$conf" <<EOF
# =========================
# DHCP Config (auto-generated)
# Scope: $scope_name
# =========================
authoritative;
default-lease-time $lease_seconds;
max-lease-time $lease_seconds;

option domain-name-servers $dns;
option routers $gateway;

subnet $subnet netmask $netmask {
  range $range_start $range_end;
}
EOF

  echo "[OK] Configuración escrita en $conf"
}

set_iface_and_enable() {
  local iface="$1"
  local defaults="/etc/default/isc-dhcp-server"

  if [[ -f "$defaults" ]]; then
    # set INTERFACESv4="iface"
    if grep -q '^INTERFACESv4=' "$defaults"; then
      sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$iface\"/" "$defaults"
    else
      echo "INTERFACESv4=\"$iface\"" >> "$defaults"
    fi
    echo "[OK] Interfaz configurada en $defaults -> $iface"
  else
    echo "[WARN] No existe $defaults (en tu distro puede variar)."
  fi

  echo "[INFO] Validando sintaxis DHCP (dhcpd -t)..."
  dhcpd -t -cf /etc/dhcp/dhcpd.conf

  systemctl enable isc-dhcp-server >/dev/null
  systemctl restart isc-dhcp-server
  echo "[OK] Servicio reiniciado y habilitado."
}

monitor_menu() {
  while true; do
    echo ""
    echo "===== MONITOREO DHCP (Linux) ====="
    echo "1) Ver estado del servicio"
    echo "2) Ver leases activas (archivo dhcpd.leases)"
    echo "3) Ver últimos logs (journalctl)"
    echo "4) Salir"
    read -rp "Opción: " opt

    case "$opt" in
      1)
        systemctl status isc-dhcp-server --no-pager
        ;;
      2)
        local leases="/var/lib/dhcp/dhcpd.leases"
        if [[ -f "$leases" ]]; then
          echo "---- Leases (resumen) ----"
          awk '
            $1=="lease"{ip=$2}
            $1=="starts"{s=$0}
            $1=="ends"{e=$0}
            $1=="hardware"{h=$0}
            $1=="}"{print ip"\n  "s"\n  "e"\n  "h"\n"}
          ' "$leases" | sed '/^\s*$/d' | tail -n 120
        else
          echo "No existe $leases"
        fi
        ;;
      3)
        journalctl -u isc-dhcp-server -n 80 --no-pager
        ;;
      4) break ;;
      *) echo "Opción inválida." ;;
    esac
  done
}

main() {
  require_root
  install_idempotent

  echo ""
  echo "===== CONFIGURACIÓN DHCP (Linux) ====="
  local scope_name subnet netmask start_ip end_ip lease_min lease_seconds gw dns iface

  scope_name="$(prompt_nonempty "Nombre del Scope (descriptivo)")"

  # Por tu práctica, default 192.168.100.0/24:
  read -rp "Subnet (default 192.168.100.0): " subnet
  subnet="${subnet:-77.77.77.1}"
  while ! is_valid_ipv4 "$subnet"; do
    echo "  -> IPv4 inválida."
    read -rp "Subnet: " subnet
  done

  read -rp "Netmask (default 255.255.255.0): " netmask
  netmask="${netmask:-255.255.255.0}"
  while ! is_valid_ipv4 "$netmask"; do
    echo "  -> IPv4 inválida."
    read -rp "Netmask: " netmask
  done

  start_ip="$(prompt_ipv4 "Rango inicial (ej. 192.168.100.50)")"
  end_ip="$(prompt_ipv4 "Rango final (ej. 192.168.100.150)")"

  if (( "$(ip_to_int "$start_ip")" > "$(ip_to_int "$end_ip")" )); then
    echo "ERROR: El rango inicial es mayor que el final."
    exit 1
  fi

  lease_min="$(prompt_int "Lease Time en minutos" 1 10080)"
  lease_seconds=$(( lease_min * 60 ))

  gw="$(prompt_ipv4 "Gateway/Router (ej. 192.168.100.1)")"
  dns="$(prompt_ipv4 "DNS (IP del servidor DNS de la práctica 1)")"

  iface="$(detect_default_iface || true)"
  read -rp "Interfaz para servir DHCP (default: ${iface:-enp0s8}): " in_iface
  iface="${in_iface:-${iface:-enp0s8}}"

  write_config "$scope_name" "$subnet" "$netmask" "$start_ip" "$end_ip" "$lease_seconds" "$gw" "$dns"
  set_iface_and_enable "$iface"

  echo ""
  echo "[DONE] DHCP configurado en Linux."
  monitor_menu
}

main "$@"
