#!/usr/bin/env bash
# =============================================================
# ftp_lib.sh — Librería de utilidades y validaciones para
#              ftp_linux.sh (vsftpd)
# Uso: source "$(dirname "$0")/ftp_lib.sh"
# =============================================================

# ── Constantes globales ───────────────────────────────────────
readonly FTP_ROOT="/srv/ftp"
readonly VSFTPD_CONF="/etc/vsftpd.conf"
readonly GROUPS=("reprobados" "recursadores")
readonly PASV_MIN=40000
readonly PASV_MAX=40100

# ═══════════════════════════════════════════════════════════════
# VALIDACIONES DE ENTORNO
# ═══════════════════════════════════════════════════════════════

# Verifica que el script se ejecute como root
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Ejecuta como root (sudo bash $0)."
    exit 1
  fi
}

# Devuelve verdadero si el usuario del sistema existe
user_exists() {
  id "$1" &>/dev/null
}

# Devuelve verdadero si el grupo del sistema existe
group_exists() {
  getent group "$1" &>/dev/null
}

# Verifica que vsftpd esté instalado y activo
assert_vsftpd_running() {
  if ! dpkg -s vsftpd &>/dev/null 2>&1; then
    echo "ERROR: vsftpd no está instalado. Ejecuta la opción 1 del menú."
    return 1
  fi
  if ! systemctl is-active --quiet vsftpd; then
    echo "WARN: vsftpd está instalado pero no está corriendo. Reiniciando..."
    systemctl start vsftpd
  fi
}

# ═══════════════════════════════════════════════════════════════
# VALIDACIONES DE FORMATO / TIPO DE DATO
# ═══════════════════════════════════════════════════════════════

# Devuelve 0 si $1 es un nombre de usuario válido (alphanum + _ -)
is_valid_username() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,31}$ ]]
}

# Devuelve 0 si $1 es una contraseña no vacía de al menos 4 caracteres
is_valid_password() {
  local pass="$1"
  [[ ${#pass} -ge 4 ]]
}

# Devuelve 0 si $1 es un entero dentro del rango [$2, $3]
is_valid_int() {
  local val="$1" min="$2" max="$3"
  [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max ))
}

# Devuelve 0 si $1 es un grupo FTP válido (reprobados o recursadores)
is_valid_group() {
  local grp="$1"
  for g in "${GROUPS[@]}"; do
    [[ "$g" == "$grp" ]] && return 0
  done
  return 1
}

# ═══════════════════════════════════════════════════════════════
# PROMPTS INTERACTIVOS (con re-intento automático)
# ═══════════════════════════════════════════════════════════════

# Solicita un string no vacío y lo devuelve por stdout
prompt_nonempty() {
  local label="$1"
  local val=""
  while true; do
    read -rp "  $label: " val
    if [[ -n "$val" ]]; then
      echo "$val"
      return 0
    fi
    echo "    → No puede ir vacío." >&2
  done
}

# Solicita un nombre de usuario válido (formato + no existente)
prompt_new_username() {
  local val=""
  while true; do
    read -rp "  Nombre de usuario: " val
    if ! is_valid_username "$val"; then
      echo "    → Nombre inválido. Usa letras, números, _ o - (empieza con letra, máx 32 chars)." >&2
    elif user_exists "$val"; then
      echo "    → El usuario '$val' ya existe. Elige otro nombre." >&2
    else
      echo "$val"
      return 0
    fi
  done
}

# Solicita un nombre de usuario que debe ya existir
prompt_existing_username() {
  local val=""
  while true; do
    read -rp "  Nombre de usuario: " val
    if user_exists "$val"; then
      echo "$val"
      return 0
    fi
    echo "    → El usuario '$val' no existe." >&2
  done
}

# Solicita una contraseña de forma segura (sin eco, validación de longitud)
prompt_password() {
  local label="${1:-Contraseña}"
  local pass=""
  while true; do
    read -rsp "  $label (mín 4 caracteres): " pass; echo "" >&2
    if is_valid_password "$pass"; then
      echo "$pass"
      return 0
    fi
    echo "    → Contraseña demasiado corta (mínimo 4 caracteres)." >&2
  done
}

# Solicita un entero dentro del rango [$2, $3]
prompt_int() {
  local label="$1" min="$2" max="$3"
  local val=""
  while true; do
    read -rp "  $label ($min-$max): " val
    if is_valid_int "$val" "$min" "$max"; then
      echo "$val"
      return 0
    fi
    echo "    → Número inválido (rango $min-$max)." >&2
  done
}

# Muestra el listado de grupos y devuelve el nombre del grupo elegido
prompt_group() {
  local val=""
  while true; do
    echo "  Grupos disponibles:" >&2
    for i in "${!GROUPS[@]}"; do
      echo "    $((i+1))) ${GROUPS[$i]}" >&2
    done
    read -rp "  Selecciona grupo (1-${#GROUPS[@]}): " val
    if is_valid_int "$val" 1 "${#GROUPS[@]}"; then
      echo "${GROUPS[$((val-1))]}"
      return 0
    fi
    echo "    → Opción inválida." >&2
  done
}

# Solicita confirmación s/n y devuelve 0 si el usuario responde "s"
prompt_confirm() {
  local label="${1:-¿Confirmas?}"
  local resp=""
  read -rp "  $label [s/N]: " resp
  [[ "$resp" =~ ^[sS]$ ]]
}

# ═══════════════════════════════════════════════════════════════
# UTILIDADES DE SALIDA (logging con color)
# ═══════════════════════════════════════════════════════════════

# Colores ANSI
_CLR_GREEN='\033[0;32m'
_CLR_CYAN='\033[0;36m'
_CLR_YELLOW='\033[1;33m'
_CLR_RED='\033[0;31m'
_CLR_RESET='\033[0m'

log_ok()   { printf "${_CLR_GREEN}[OK]   %s${_CLR_RESET}\n" "$*"; }
log_info() { printf "${_CLR_CYAN}[INFO] %s${_CLR_RESET}\n"  "$*"; }
log_warn() { printf "${_CLR_YELLOW}[WARN] %s${_CLR_RESET}\n" "$*"; }
log_err()  { printf "${_CLR_RED}[ERR]  %s${_CLR_RESET}\n"   "$*" >&2; }

print_banner() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║       SERVIDOR FTP — LINUX (vsftpd)          ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""
}

print_separator() {
  echo "──────────────────────────────────────────────"
}
