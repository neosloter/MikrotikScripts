# =====================================================================
# MikroTik RouterOS v7 - Cloud CHR Hardened Configuration
# Custom profile for CHR (IP: 6.60.4.15, SSTP: 25252, api-ssl: 15.15.10.2)
# Architecture: vasilevkirill.ru & mikrotik-training.ru
# =====================================================================

# -------------------------------------------------------------
# 1. INTERFACE LISTS & ADDRESS LISTS (Zoning)
# -------------------------------------------------------------
/interface list
add name=WAN comment="Public Internet Uplink"
add name=Management comment="Management Zone"

/interface list member
add interface=ether1 list=WAN

/ip firewall address-list
# Whitelist: Administrator (SSTP client 15.15.10.2)
add list=TRUSTED-MGMT address=15.15.10.2 comment="Admin SSTP Client IP"
# Note: If accessing Winbox directly from your static public IP, add it here:
# add list=TRUSTED-MGMT address=X.X.X.X comment="Admin Office Static IP"

# -------------------------------------------------------------
# 2. RAW FIREWALL (Prerouting drops before Connection Tracker)
# -------------------------------------------------------------
/ip firewall raw
# TCP flags sanity check (Drop Nmap scans: XMAS, NULL, SYN-FIN)
add chain=prerouting protocol=tcp tcp-flags=!fin,!syn,!rst,!ack action=drop comment="RAW: Drop TCP Null"
add chain=prerouting protocol=tcp tcp-flags=fin,syn action=drop comment="RAW: Drop TCP SYN-FIN"
add chain=prerouting protocol=tcp tcp-flags=fin,rst action=drop comment="RAW: Drop TCP SYN-RST"
add chain=prerouting protocol=tcp tcp-flags=fin,!ack action=drop comment="RAW: Drop TCP FIN no ACK"
add chain=prerouting protocol=tcp tcp-flags=fin,psh,urg,!syn,!rst,!ack action=drop comment="RAW: Drop TCP Xmas"

# Instant drop for blacklisted hosts
add chain=prerouting src-address-list=Blacklist action=drop comment="RAW: Drop Blacklist immediately"

# -------------------------------------------------------------
# 3. CUSTOM DEFENSE CHAIN (Defense-Scans)
# -------------------------------------------------------------
/ip firewall filter
# Whitelist bypass: Never block administrator
add chain=Defense-Scans src-address-list=TRUSTED-MGMT action=return comment="Whitelist: Never block admin"
add chain=Defense-Scans src-address-list=Blacklist action=drop comment="Drop already blacklisted"

# Honeypots: Instant ban on probing vulnerable service ports
add chain=Defense-Scans protocol=tcp dst-port=21,22,23,445,1433,3306,3389,5900,8080 \
    action=add-src-to-address-list address-list=Blacklist address-list-timeout=1d log=yes log-prefix="[HONEYPOT-BAN]" comment="Honeypot probe: Instant 24h ban"
add chain=Defense-Scans protocol=tcp dst-port=21,22,23,445,1433,3306,3389,5900,8080 action=drop comment="Drop Honeypot probe"

# Port Scan Detection (PSD)
add chain=Defense-Scans protocol=tcp psd=21,3s,3,1 \
    action=add-src-to-address-list address-list=Blacklist address-list-timeout=1d log=yes log-prefix="[PSD-BAN]" comment="PSD Port Scan: 24h ban"
add chain=Defense-Scans protocol=tcp psd=21,3s,3,1 action=drop comment="Drop Port scan"

# Brute-force protection for SSTP (25252) and Winbox (8291)
# Stage 3 -> Final 24h Ban
add chain=Defense-Scans connection-state=new protocol=tcp dst-port=25252,8291 src-address-list=Brute-Stage-2 \
    action=add-src-to-address-list address-list=Blacklist address-list-timeout=1d log=yes log-prefix="[BRUTEFORCE-BAN]" comment="Brute-Force: Stage 3 -> Final Ban"
add chain=Defense-Scans protocol=tcp dst-port=25252,8291 src-address-list=Blacklist action=drop comment="Drop newly banned attacker"
# Stage 2
add chain=Defense-Scans connection-state=new protocol=tcp dst-port=25252,8291 src-address-list=Brute-Stage-1 \
    action=add-src-to-address-list address-list=Brute-Stage-2 address-list-timeout=1m comment="Brute-Force: Stage 2"
# Stage 1
add chain=Defense-Scans connection-state=new protocol=tcp dst-port=25252,8291 \
    action=add-src-to-address-list address-list=Brute-Stage-1 address-list-timeout=1m comment="Brute-Force: Stage 1"

# -------------------------------------------------------------
# 4. FILTER FIREWALL (Default-Drop Architecture)
# -------------------------------------------------------------

# --- INPUT CHAIN ---
add chain=input connection-state=invalid action=drop comment="Drop invalid connections"
add chain=input connection-state=established,related,untracked action=accept comment="Accept established,related,untracked"

# JUMP RULE: Check new inbound WAN connections in Defense-Scans
add chain=input in-interface-list=WAN action=jump jump-target=Defense-Scans comment="Jump to Defense-Scans chain"

# ICMP rate limiting
add chain=input protocol=icmp limit=5,10:packet action=accept comment="Accept ICMP limited (Anti-flood)"
add chain=input protocol=icmp action=drop comment="Drop excess ICMP"

# 1. SSTP VPN Server (Publicly open for clients)
add chain=input in-interface-list=WAN protocol=tcp dst-port=25252 action=accept comment="Allow SSTP VPN Server (port 25252)"

# 2. API-SSL (Strictly restricted to 15.15.10.2 / TRUSTED-MGMT)
add chain=input protocol=tcp dst-port=8729 src-address-list=TRUSTED-MGMT action=accept comment="Allow API-SSL ONLY from TRUSTED-MGMT (15.15.10.2)"

# 3. Winbox (Strictly restricted to TRUSTED-MGMT)
add chain=input protocol=tcp dst-port=8291 src-address-list=TRUSTED-MGMT action=accept comment="Allow Winbox ONLY from TRUSTED-MGMT"

# DEFAULT DROP FOR INPUT
add chain=input action=drop comment="DEFAULT-DROP: Block all other input"

# --- FORWARD CHAIN ---
add chain=forward connection-state=invalid action=drop comment="Drop invalid connections"
add chain=forward connection-state=established,related action=accept comment="Accept established,related"

# Allow SSTP clients (15.15.10.0/24) to reach the Internet via CHR
add chain=forward src-address=15.15.10.0/24 out-interface-list=WAN action=accept comment="Allow SSTP Clients to Internet"

# DEFAULT DROP FOR FORWARD
add chain=forward action=drop comment="DEFAULT-DROP: Block all other forward"

# -------------------------------------------------------------
# 5. SYSTEM HARDENING FOR CLOUD CHR
# -------------------------------------------------------------

# Disable insecure unauthenticated Bandwidth Server
/tool bandwidth-server set enabled=no

# Disable L2 discovery in cloud environment (Hide from hypervisor neighbors)
/ip neighbor discovery-settings set discover-interface-list=none
/tool mac-server set allowed-interface-list=none
/tool mac-server mac-winbox set allowed-interface-list=none
/tool mac-server ping set enabled=no

# Service hardening (/ip service)
/ip service
set ftp disabled=yes
set telnet disabled=yes
set www disabled=yes
set ssh disabled=yes
set api disabled=yes

# api-ssl: enabled with mtm-api-ssl certificate and IP restriction
set api-ssl certificate=mtm-api-ssl address=15.15.10.2/32 disabled=no

# winbox: restricted to trusted address 15.15.10.2
set winbox address=15.15.10.2/32 disabled=no

# -------------------------------------------------------------
# 6. TIME (NTP) & SECURE DNS
# -------------------------------------------------------------
/system clock set time-zone-name="Europe/Moscow"
/system ntp client set enabled=yes
/system ntp client servers
add address="pool.ntp.org"
add address="time.google.com"

# Prevent DNS relay abuse (Drop external DNS requests)
/ip dns set allow-remote-requests=no servers=1.1.1.1,8.8.8.8
