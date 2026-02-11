#!/bin/bash
color="\e[35m"
reset="\e[0m"


#Actualizacion del sistema
echo -e "${color}Actualizando el sistema...${reset}"
apt-get update -y
apt-get upgrade -y

#Instalacion del servicio
echo -e "${color}Instalando el servicio de DHCP....${reset}"
apt-get install isc-dhcp-server ipcalc -y

#Cambio de interfaz v4
echo -e "${color}Cambiando la interfaz de v4 a la correspondiente...${reset}"
sed -i 's/^INTERFACESv4=""/INTERFACESv4="enp0s8"/' /etc/default/isc-dhcp-server

#Funciones aparte
BROADCAST=""
NETWORK=""
MASCARA=""
# Función para calcular el segmento de red y broadcast
calcular_red_broadcast() {
    local ip="$1"
    local mask="255.255.255.0"

    # Extraer los primeros tres octetos de la IP
    local base=$(echo "$ip" | awk -F. '{print $1"."$2"."$3}')

    # Asignar los valores globalmente
    NETWORK="${base}.0"
    BROADCAST="${base}.255"
}


calcular_mascara_subred() {
    local cidr=$1

    # Inicializar la máscara de subred
    local mascara=""

    # Calcular la máscara de subred basada en el CIDR
    for i in {1..32}; do
        if [ $i -le $cidr ]; then
            mascara+="1"
        else
            mascara+="0"
        fi

        # Agregar un punto cada 8 bits
        if [ $((i % 8)) -eq 0 ] && [ $i -ne 32 ]; then
            mascara+="."
        fi
    done

    # Convertir la máscara binaria a formato decimal
    local octetos=(${mascara//./ })
    local mascara_decimal=""

    for octeto in "${octetos[@]}"; do
        mascara_decimal+=$((2#$octeto))
        mascara_decimal+="."
    done

    # Eliminar el último punto
    MASCARA="${mascara_decimal%?}"
}

#Pedir los datos
read -p "$Ingrese la ip para el servidor: " ipserver
calcular_red_broadcast "$ipserver"
cidr=24
calcular_mascara_subred "$cidr"

read -p "Ingrese el inicio del rango deseado: " iniciorango

read -p "Ingrese el final del rango deseado: " finalrango


if [[ -z "$NETWORK" || -z "$MASCARA" || -z "$BROADCAST" ]]; then
    echo "Error: No se pudo obtener la configuración de red."
    exit 1
fi

#Configuracion de IP Estatica
echo -e "${color}Empezando proceso de asignacion de ip estatica a la red local.....${reset}"
echo -e "${color}Generando copia de seguridad del archivo de configuracion de NetPlan....${reset}"
sudo cp /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.bak  # Copia de seguridad

echo -e "${color}Empezando la insercion de nueva informacion al archivo..${reset}"
cat << EOF | sudo tee /etc/netplan/50-cloud-init.yaml
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true

    enp0s8:
      dhcp4: false
      addresses:
        - ${ipserver}/24
      gateway4: ${ipserver}
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
EOF

# Aplicar cambios
echo -e "${color}Aplicando cambios en los adaptadores de red de la maquina....${reset}"
sudo netplan apply


#Configuracion del DHCP
echo -e "${color}Comenzando insercion de la configuracion en archivo para el servicio...${reset}"

ruta="/etc/dhcp/dhcpd.conf"

cat << EOF | sudo tee -a "$ruta"

#Configuracion de la subred
subnet $NETWORK netmask $MASCARA {
  range $iniciorango $finalrango;
  option routers $ipserver;
  option subnet-mask $MASCARA;
  option domain-name-servers 8.8.8.8, 8.8.4.4;
  option broadcast-address $BROADCAST;
}
EOF

#Reinicio de servicio
echo -e "${color}Reiniciando el servicio DHCP....${reset}"
systemctl restart isc-dhcp-server

echo -e "${color}Verificando si esta funcionando....${reset}"
systemctl status isc-dhcp-server