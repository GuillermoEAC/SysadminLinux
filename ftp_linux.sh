#!/usr/bin/env bash
# =============================================================
# ftp_linux.sh — Servidor FTP automatizado en Linux (vsftpd)
#
# Lógica de negocio principal. Las validaciones, prompts y
# helpers están en ftp_lib.sh (sourced al inicio).
#
# Ejecutar como root:   sudo bash ftp_linux.sh
# =============================================================
set -euo pipefail

# ── Importar librería de utilidades ──────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ftp_lib.sh"

# ═══════════════════════════════════════════════════════════════
# 1. INSTALACIÓN IDEMPOTENTE
# ═══════════════════════════════════════════════════════════════

install_idempotent() {
  log_info "Verificando instalación de vsftpd..."
  if dpkg -s vsftpd &>/dev/null 2>&1; then
    log_ok "vsftpd ya está instalado."
  else
    log_info "Instalando vsftpd..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -q
    apt-get install -y -q vsftpd
    log_ok "vsftpd instalado correctamente."
  fi
  systemctl enable vsftpd &>/dev/null
  systemctl start  vsftpd &>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# 2. CONFIGURACIÓN DE vsftpd.conf (Idempotente con backup)
# ═══════════════════════════════════════════════════════════════

configure_vsftpd() {
  local backup="${VSFTPD_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
  local server_ip
  server_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || server_ip=""

  if [[ -f "$VSFTPD_CONF" ]]; then
    cp "$VSFTPD_CONF" "$backup"
    log_info "Backup creado: $backup"
  fi

  cat > "$VSFTPD_CONF" <<EOF
# ============================================================
# vsftpd.conf — Generado automáticamente por ftp_linux.sh
# ============================================================

listen=YES
listen_ipv6=NO

# ── Acceso local y escritura ─────────────────────────────────
anonymous_enable=YES
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
xferlog_file=/var/log/vsftpd.log
connect_from_port_20=YES
idle_session_timeout=600
data_connection_timeout=120

# ── Acceso anónimo (solo lectura en ${FTP_ROOT}) ─────────────
anon_root=${FTP_ROOT}
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO

# ── Chroot por usuario (raíz en /home/<user>/ftp) ───────────
chroot_local_user=YES
allow_writeable_chroot=NO
chroot_list_enable=NO
user_sub_token=\$USER
local_root=/home/\$USER/ftp

# ── Modo pasivo ──────────────────────────────────────────────
pasv_enable=YES
pasv_min_port=${PASV_MIN}
pasv_max_port=${PASV_MAX}
${server_ip:+pasv_address=${server_ip}}

# ── Seguridad ────────────────────────────────────────────────
ftpd_banner=Bienvenido al servidor FTP
pam_service_name=vsftpd
tcp_wrappers=NO
EOF

  systemctl restart vsftpd
  log_ok "vsftpd.conf configurado y servicio reiniciado."
}

# ═══════════════════════════════════════════════════════════════
# 3. GRUPOS Y ESTRUCTURA DE CARPETAS RAÍZ
# ═══════════════════════════════════════════════════════════════

create_groups() {
  log_info "Verificando grupos FTP..."
  for grp in "${GROUPS[@]}"; do
    if group_exists "$grp"; then
      log_ok "Grupo '$grp' ya existe."
    else
      groupadd "$grp"
      log_ok "Grupo '$grp' creado."
    fi
  done
}

setup_ftp_root() {
  log_info "Configurando directorio raíz FTP: ${FTP_ROOT}"

  mkdir -p "${FTP_ROOT}"
  chown root:root "${FTP_ROOT}"
  chmod 755 "${FTP_ROOT}"

  # Carpeta general: anónimo R, usuarios autenticados RW
  mkdir -p "${FTP_ROOT}/general"
  chown root:root "${FTP_ROOT}/general"
  chmod 777 "${FTP_ROOT}/general"

  # Carpetas por grupo
  for grp in "${GROUPS[@]}"; do
    mkdir -p "${FTP_ROOT}/${grp}"
    chown root:"${grp}" "${FTP_ROOT}/${grp}"
    chmod 775 "${FTP_ROOT}/${grp}"
    log_ok "Carpeta ${FTP_ROOT}/${grp} lista."
  done
}

# ═══════════════════════════════════════════════════════════════
# 4. GESTIÓN DE ÁRBOL CHROOT POR USUARIO
# ═══════════════════════════════════════════════════════════════

# Construye /home/<user>/ftp/{general,<grupo>,<username>} con bind mounts
_build_user_tree() {
  local username="$1" grupo="$2"
  local ftp_home="/home/${username}/ftp"

  # Raíz chroot (propietario root, sin escritura para others — req. vsftpd)
  mkdir -p "${ftp_home}"
  chown root:root "${ftp_home}"
  chmod 755 "${ftp_home}"

  # Carpeta personal (escritura exclusiva del usuario)
  mkdir -p "${ftp_home}/${username}"
  chown "${username}:${username}" "${ftp_home}/${username}"
  chmod 755 "${ftp_home}/${username}"

  # general → bind mount de /srv/ftp/general
  mkdir -p "${ftp_home}/general"
  chown root:root "${ftp_home}/general"
  chmod 755 "${ftp_home}/general"
  _ensure_bindmount "${FTP_ROOT}/general" "${ftp_home}/general"

  # grupo → bind mount del grupo FTP
  mkdir -p "${ftp_home}/${grupo}"
  chown root:"${grupo}" "${ftp_home}/${grupo}"
  chmod 755 "${ftp_home}/${grupo}"
  _ensure_bindmount "${FTP_ROOT}/${grupo}" "${ftp_home}/${grupo}"
}

# Añade entrada a /etc/fstab y monta si no está montado
_ensure_bindmount() {
  local src="$1" dst="$2"
  if ! mountpoint -q "${dst}"; then
    mount --bind "${src}" "${dst}" 2>/dev/null || true
  fi
  local entry="${src} ${dst} none bind 0 0"
  if ! grep -qF "${entry}" /etc/fstab; then
    echo "${entry}" >> /etc/fstab
    log_info "fstab: ${src} → ${dst}"
  fi
}

# Desmonta y elimina el bind mount del grupo anterior
_remove_group_bindmount() {
  local username="$1" old_group="$2"
  local old_mount="/home/${username}/ftp/${old_group}"
  mountpoint -q "${old_mount}" 2>/dev/null && umount "${old_mount}" || true
  sed -i "\|${FTP_ROOT}/${old_group} /home/${username}/ftp/${old_group}|d" /etc/fstab 2>/dev/null || true
  rm -rf "${old_mount}"
}

# ═══════════════════════════════════════════════════════════════
# 5. OPERACIONES CRUD DE USUARIOS
# ═══════════════════════════════════════════════════════════════

create_user() {
  print_separator
  log_info "── Nuevo usuario FTP ──"

  local username password grupo
  username="$(prompt_new_username)"
  password="$(prompt_password)"
  grupo="$(prompt_group)"

  useradd -m -d "/home/${username}" -s /usr/sbin/nologin "${username}"
  echo "${username}:${password}" | chpasswd
  usermod -aG "${grupo}" "${username}"
  _build_user_tree "${username}" "${grupo}"

  log_ok "Usuario '${username}' creado en grupo '${grupo}'."
  echo "       Árbol FTP visible al hacer login:"
  echo "         ├── general/"
  echo "         ├── ${grupo}/"
  echo "         └── ${username}/"
}

change_user_group() {
  print_separator
  log_info "── Cambiar grupo de usuario ──"

  local username current_group="" new_group
  username="$(prompt_existing_username)"

  for grp in "${GROUPS[@]}"; do
    if id -nG "${username}" | grep -qw "${grp}"; then
      current_group="${grp}"; break
    fi
  done
  echo "  Grupo actual: ${current_group:-ninguno}"

  new_group="$(prompt_group)"
  if [[ "$new_group" == "$current_group" ]]; then
    log_warn "El usuario ya pertenece a '${new_group}'. Sin cambios."; return 0
  fi

  [[ -n "$current_group" ]] && gpasswd -d "${username}" "${current_group}" &>/dev/null || true
  [[ -n "$current_group" ]] && _remove_group_bindmount "${username}" "${current_group}"

  usermod -aG "${new_group}" "${username}"
  local ftp_home="/home/${username}/ftp"
  mkdir -p "${ftp_home}/${new_group}"
  chown root:"${new_group}" "${ftp_home}/${new_group}"
  chmod 755 "${ftp_home}/${new_group}"
  _ensure_bindmount "${FTP_ROOT}/${new_group}" "${ftp_home}/${new_group}"

  log_ok "Usuario '${username}' movido de '${current_group:-ninguno}' → '${new_group}'."
}

delete_user() {
  print_separator
  log_info "── Eliminar usuario FTP ──"

  local username
  username="$(prompt_existing_username)"

  if ! prompt_confirm "¿Eliminar al usuario '${username}' y su carpeta?"; then
    log_warn "Operación cancelada."; return 0
  fi

  local ftp_home="/home/${username}/ftp"
  for grp in "${GROUPS[@]}"; do
    mountpoint -q "${ftp_home}/${grp}" 2>/dev/null && umount "${ftp_home}/${grp}" || true
    sed -i "\|${FTP_ROOT}/${grp} ${ftp_home}/${grp}|d" /etc/fstab 2>/dev/null || true
  done
  mountpoint -q "${ftp_home}/general" 2>/dev/null && umount "${ftp_home}/general" || true
  sed -i "\|${FTP_ROOT}/general ${ftp_home}/general|d" /etc/fstab 2>/dev/null || true

  userdel -r "${username}" 2>/dev/null || true
  log_ok "Usuario '${username}' eliminado."
}

list_users() {
  echo ""
  printf "  %-20s %-15s %-30s\n" "USUARIO" "GRUPO FTP" "HOME FTP"
  print_separator
  local any=false
  for grp in "${GROUPS[@]}"; do
    if group_exists "$grp"; then
      local members
      members=$(getent group "$grp" | cut -d: -f4)
      if [[ -n "$members" ]]; then
        IFS=',' read -ra users <<< "$members"
        for u in "${users[@]}"; do
          printf "  %-20s %-15s %-30s\n" "$u" "$grp" "/home/$u/ftp"
          any=true
        done
      fi
    fi
  done
  $any || echo "  (ningún usuario FTP registrado)"
}

# ═══════════════════════════════════════════════════════════════
# 6. MENÚ DE GESTIÓN DE USUARIOS
# ═══════════════════════════════════════════════════════════════

user_menu() {
  while true; do
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║       GESTIÓN DE USUARIOS FTP        ║"
    echo "╠══════════════════════════════════════╣"
    echo "║ 1) Crear N usuarios                  ║"
    echo "║ 2) Crear 1 usuario                   ║"
    echo "║ 3) Cambiar grupo de usuario          ║"
    echo "║ 4) Eliminar usuario                  ║"
    echo "║ 5) Listar usuarios FTP               ║"
    echo "║ 6) Volver al menú principal          ║"
    echo "╚══════════════════════════════════════╝"
    local opt
    read -rp "  Opción: " opt
    case "$opt" in
      1)
        local n; n="$(prompt_int "Número de usuarios a crear" 1 100)"
        for (( i=1; i<=n; i++ )); do
          echo ""; log_info "── Usuario $i de $n ──"; create_user
        done
        log_ok "$n usuario(s) creado(s)." ;;
      2) create_user ;;
      3) change_user_group ;;
      4) delete_user ;;
      5) list_users ;;
      6) return 0 ;;
      *) log_warn "Opción inválida." ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════
# 7. MENÚ DE MONITOREO
# ═══════════════════════════════════════════════════════════════

monitor_menu() {
  while true; do
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║        MONITOREO vsftpd              ║"
    echo "╠══════════════════════════════════════╣"
    echo "║ 1) Estado del servicio               ║"
    echo "║ 2) Conexiones FTP activas            ║"
    echo "║ 3) Últimas líneas del log            ║"
    echo "║ 4) Usuarios y grupos                 ║"
    echo "║ 5) Bind mounts activos               ║"
    echo "║ 6) Volver al menú principal          ║"
    echo "╚══════════════════════════════════════╝"
    local opt
    read -rp "  Opción: " opt
    case "$opt" in
      1) echo ""; systemctl status vsftpd --no-pager || true ;;
      2) echo ""; ss -tnp 'sport = :21 or dport = :21' 2>/dev/null ||
           netstat -tnp 2>/dev/null | grep ':21' ||
           echo "  (sin conexiones activas)" ;;
      3) echo ""
         if [[ -f /var/log/vsftpd.log ]]; then tail -n 40 /var/log/vsftpd.log
         else journalctl -u vsftpd -n 40 --no-pager 2>/dev/null || echo "  (log no disponible)"; fi ;;
      4) echo ""; for grp in "${GROUPS[@]}"; do
           echo "  ${grp}: $(getent group "$grp" 2>/dev/null | cut -d: -f4 || echo '<sin usuarios>')"; done ;;
      5) echo ""; mount | grep "${FTP_ROOT}" || echo "  (ninguno)" ;;
      6) return 0 ;;
      *) log_warn "Opción inválida." ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════
# 8. MENÚ PRINCIPAL
# ═══════════════════════════════════════════════════════════════

main_menu() {
  while true; do
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║        MENÚ PRINCIPAL FTP            ║"
    echo "╠══════════════════════════════════════╣"
    echo "║ 1) Instalar/Actualizar vsftpd        ║"
    echo "║ 2) (Re)Configurar vsftpd.conf        ║"
    echo "║ 3) Gestión de usuarios               ║"
    echo "║ 4) Monitoreo                         ║"
    echo "║ 5) Salir                             ║"
    echo "╚══════════════════════════════════════╝"
    local opt
    read -rp "  Opción: " opt
    case "$opt" in
      1) install_idempotent ;;
      2) configure_vsftpd ;;
      3) user_menu ;;
      4) monitor_menu ;;
      5) echo ""; echo "  ¡Hasta luego!"; exit 0 ;;
      *) log_warn "Opción inválida." ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════

main() {
  require_root
  print_banner

  log_info "Inicializando entorno FTP..."
  install_idempotent
  create_groups
  setup_ftp_root
  configure_vsftpd

  echo ""; log_ok "Entorno FTP listo."; sleep 1
  main_menu
}

main "$@"
