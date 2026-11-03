# Stage 2 — Step 3: Hybrid IPsec Site-to-Site VPN Manual Runbook
**Document ID**: RUNBOOK-STAGE2-STEP3-VPN-MANUAL-20261103  
**Target Audience**: Cloud Engineers, Network Architects, DevSecOps  
**Lab Context**: Connecting On-Premises Hypervisor (`HV01` on Azure) to Target AWS Landing Zone  
**Status**: Step-by-Step Hands-on Learning Guide  

---

## 1. Architectural Overview & Network Parameters

A Site-to-Site (S2S) IPsec VPN creates a secure, encrypted Layer 3 bridge between two private networks traversing the public internet.

```
+--------------------------------------------------------------------------------------------------+
| ON-PREMISES DATACENTER (AZURE)                     | TARGET MIGRATION LANDING ZONE (AWS)         |
| Public IP: 172.212.155.105 (HV01 Edge Router)      | Region: us-east-1                           |
| Private CIDR: 10.10.0.0/16                         | Target VPC: vpc-011dd8140a94ceb4b           |
| Guest Subnet: 10.10.10.0/24 (virbr1)               | VPC CIDR: 10.20.0.0/16                      |
|                                                    |                                             |
| +------------------------------------------------+ | +-----------------------------------------+ |
| | Guest VMs (virbr1):                            | | | Target AWS Subnets:                     | |
| |  - DC01   (AD / DNS)    : 10.10.10.10          | | |  - App Subnets: 10.20.10.0/24, .11.0/24| |
| |  - APP01  (Nginx / Node): 10.10.10.20          | | |  - DB Subnets : 10.20.20.0/24, .21.0/24| |
| |  - DB01   (PostgreSQL)  : 10.10.10.30          | | +-----------------------------------------+ |
| |  - FILE01 (Samba CIFS)  : 10.10.10.40          | |                      ^                      |
| +------------------------------------------------+ |                      |                      |
|                        |                           |                      |                      |
|                        v                           |                      v                      |
|            [StrongSwan IPsec Daemon]               |       [Virtual Private Gateway (VGW)]       |
|                 (on HV01 Host)                     |            (Attached to Target VPC)         |
|                        |                           |                      |                      |
|                        +===========================+======================+                      |
|                               Encrypted IPsec Tunnel Over WAN                                    |
|                             Route: 10.10.0.0/16 <-> 10.20.0.0/16                                 |
+--------------------------------------------------------------------------------------------------+
```

### Parameter Reference Table

| Parameter | Value | Description |
| :--- | :--- | :--- |
| **On-Prem Edge Public IP** | `172.212.155.105` | Public IP of `HV01` (Customer Gateway) |
| **On-Prem Host Private IP** | `10.10.1.10` | Primary Azure NIC IP of `HV01` |
| **On-Prem Network CIDR** | `10.10.0.0/16` | Complete On-Prem Address Space |
| **On-Prem Guest Subnet** | `10.10.10.0/24` | `virbr1` subnet hosting `DC01`, `DB01`, etc. |
| **AWS Target VPC ID** | `vpc-011dd8140a94ceb4b` | Active AWS Landing Zone VPC |
| **AWS Target CIDR** | `10.20.0.0/16` | Target AWS VPC Address Space |
| **AWS Region** | `us-east-1` | Target AWS Cloud Region |
| **IPsec Protocol** | `IKEv2` | Internet Key Exchange Version 2 |
| **Encryption Algorithm** | `AES-256-GCM` or `AES-256-CBC` | Bulk data encryption |
| **Integrity Algorithm** | `SHA2-256` | Cryptographic packet validation |
| **Diffie-Hellman Group** | Group 14 (MODP 2048-bit) | Key exchange algorithm |

---

## 2. Part 1: AWS Side Configuration

You can execute the AWS configuration either via the **AWS Management Console** or directly using the **AWS CLI**.

### Step 1.1: Create the Customer Gateway (CGW)
The Customer Gateway tells AWS where your on-premises edge router is located on the internet.

* **Console**: Go to **VPC > Virtual private network (VPN) > Customer gateways > Create customer gateway**.
  - Name: `cgw-hv01-onprem`
  - BGP ASN: `65000` (Default)
  - IP address: `172.212.155.105`
  - Certificate ARN: Leave blank
* **AWS CLI command**:
  ```bash
  aws ec2 create-customer-gateway \
    --type ipsec.1 \
    --public-ip 172.212.155.105 \
    --bgp-asn 65000 \
    --tag-specifications 'ResourceType=customer-gateway,Tags=[{Key=Name,Value=cgw-hv01-onprem},{Key=Project,Value=Enterprise-Cloud-Migration-Lab}]' \
    --region us-east-1
  ```
  *Make note of the output `CustomerGatewayId` (e.g., `cgw-0123456789abcdef0`).*

---

### Step 1.2: Create the Virtual Private Gateway (VGW) & Attach to VPC
The Virtual Private Gateway is the managed VPN concentrator on the AWS side.

* **Console**: Go to **VPC > Virtual private network (VPN) > Virtual private gateways > Create virtual private gateway**.
  - Name: `vgw-streamflix-target`
  - ASN: Amazon default ASN (`64512`)
  - Select the created VGW, click **Actions > Attach to VPC**, and select `vpc-011dd8140a94ceb4b`.
* **AWS CLI commands**:
  ```bash
  # 1. Create VGW
  VGW_ID=$(aws ec2 create-vpn-gateway \
    --type ipsec.1 \
    --tag-specifications 'ResourceType=vpn-gateway,Tags=[{Key=Name,Value=vgw-streamflix-target},{Key=Project,Value=Enterprise-Cloud-Migration-Lab}]' \
    --query "VpnGateway.VpnGatewayId" \
    --output text \
    --region us-east-1)

  echo "Created VGW: $VGW_ID"

  # 2. Attach VGW to Target VPC
  aws ec2 attach-vpn-gateway \
    --vpn-gateway-id "$VGW_ID" \
    --vpc-id "vpc-011dd8140a94ceb4b" \
    --region us-east-1
  ```

---

### Step 1.3: Create the Site-to-Site VPN Connection
This resource links your Customer Gateway (`HV01`) and Virtual Private Gateway together.

* **Console**: Go to **VPC > Virtual private network (VPN) > Site-to-Site VPN connections > Create VPN connection**.
  - Name: `vpn-onprem-to-aws`
  - Target gateway type: **Virtual private gateway**
  - Virtual private gateway: Select `vgw-streamflix-target`
  - Customer gateway: Select **Existing**, then choose `cgw-hv01-onprem`
  - Routing options: **Static**
  - Static IP prefixes: `10.10.0.0/16`
  - Tunnel Options: Leave defaults (AWS will auto-generate Tunnel IPs and Pre-Shared Keys).
* **AWS CLI command**:
  ```bash
  VPN_ID=$(aws ec2 create-vpn-connection \
    --type ipsec.1 \
    --customer-gateway-id "$CGW_ID" \
    --vpn-gateway-id "$VGW_ID" \
    --options "{\"StaticRoutesOnly\":true}" \
    --tag-specifications 'ResourceType=vpn-connection,Tags=[{Key=Name,Value=vpn-onprem-to-aws},{Key=Project,Value=Enterprise-Cloud-Migration-Lab}]' \
    --query "VpnConnection.VpnConnectionId" \
    --output text \
    --region us-east-1)

  echo "Created VPN Connection: $VPN_ID"

  # Add static route for on-premises CIDR
  aws ec2 create-vpn-connection-route \
    --vpn-connection-id "$VPN_ID" \
    --destination-cidr-block "10.10.0.0/16" \
    --region us-east-1
  ```

---

### Step 1.4: Enable Route Propagation in AWS Route Tables
For AWS subnets to know how to reach `10.10.0.0/16`, their route tables must propagate routes from the VGW.

* **Console**: Go to **VPC > Route tables**, select:
  1. `streamflix-target-rt-app-private`
  2. `streamflix-target-rt-db-isolated`
  - Under the **Route propagation** tab, click **Edit route propagation**, check the box for `vgw-streamflix-target`, and click **Save**.
* **AWS CLI command**:
  ```bash
  # Get Private App Route Table ID
  APP_RT=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=vpc-011dd8140a94ceb4b" "Name=tag:Name,Values=streamflix-target-rt-app-private" \
    --query "RouteTables[0].RouteTableId" --output text --region us-east-1)

  # Get Isolated DB Route Table ID
  DB_RT=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=vpc-011dd8140a94ceb4b" "Name=tag:Name,Values=streamflix-target-rt-db-isolated" \
    --query "RouteTables[0].RouteTableId" --output text --region us-east-1)

  # Enable Propagation on both
  aws ec2 enable-vgw-route-propagation --route-table-id "$APP_RT" --gateway-id "$VGW_ID" --region us-east-1
  aws ec2 enable-vgw-route-propagation --route-table-id "$DB_RT" --gateway-id "$VGW_ID" --region us-east-1
  ```

---

### Step 1.5: Download VPN Tunnel Configuration
Once the VPN connection transitions from `pending` to `available` (usually 1–2 minutes):

* **Console**: Select `vpn-onprem-to-aws` and click **Download configuration**:
  - Vendor: **Strongswan**
  - Platform: **Ubuntu**
  - Software: **Strongswan 5.x**
* **CLI extraction**:
  ```bash
  aws ec2 describe-vpn-connections \
    --vpn-connection-ids "$VPN_ID" \
    --query "VpnConnections[0].VgwTelemetry[*].{OutsideIp:OutsideIpAddress,Status:Status}" \
    --region us-east-1
  ```
  *Take note of:*
  - **AWS Tunnel 1 Outside IP Address** (e.g., `3.210.x.x`)
  - **Pre-Shared Key (PSK)** (from the downloaded config or generated secrets)

---

## 3. Part 2: On-Premises Host (`HV01`) Configuration

Now log into your on-premises hypervisor host `HV01`.

```bash
# Connect to HV01 (via SSH or Azure Bastion)
ssh -i <your-key> labadmin@172.212.155.105
```

---

### Step 2.1: Enable Linux IP Forwarding
The Linux kernel must act as an IP router to forward packets between the IPsec tunnel and the guest bridge (`virbr1`).

Run on `HV01`:
```bash
# Enable IP forwarding immediately
sudo sysctl -w net.ipv4.ip_forward=1

# Persist across reboots
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-ip-forward.conf
sudo sysctl --system
```

---

### Step 2.2: Install StrongSwan
Install StrongSwan and its cryptographic plugins:
```bash
sudo apt update
sudo apt install -y strongswan strongswan-pki libcharon-extra-plugins libstrongswan-extra-plugins
```

Verify installation:
```bash
ipsec version
```
*(Expected: Linux strongSwan U5.9.x / U5.10.x)*

---

### Step 2.3: Configure `/etc/ipsec.conf`
The `/etc/ipsec.conf` file defines the IPsec connection policies, IKE cryptographic proposals, and routing subnets.

Open the file:
```bash
sudo nano /etc/ipsec.conf
```

Replace or append the following configuration:

```ini
# /etc/ipsec.conf — StrongSwan Configuration for AWS Site-to-Site VPN
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no

conn %default
    ikelifetime=28800s
    keylife=3600s
    rekeymargin=3m
    keyingtries=%forever
    keyexchange=ikev2
    authby=secret
    mobike=no
    dpddelay=10s
    dpdtimeout=30s
    dpdaction=restart

conn aws-tunnel-1
    # Local (HV01 On-Premises)
    left=%defaultroute
    leftid=172.212.155.105
    leftsubnet=10.10.0.0/16
    leftfirewall=yes

    # Remote (AWS Virtual Private Gateway)
    # REPLACE with your AWS Tunnel 1 Outside IP from Step 1.5:
    right=<AWS_TUNNEL_1_OUTSIDE_IP>
    rightid=<AWS_TUNNEL_1_OUTSIDE_IP>
    rightsubnet=10.20.0.0/16

    # Cryptographic Suite (AWS Compatible)
    ike=aes256gcm16-sha256-modp2048,aes256-sha256-modp2048!
    esp=aes256gcm16-sha256,aes256-sha256!

    # Start tunnel automatically on daemon boot
    auto=start
```

> [!IMPORTANT]
> **Line-by-line explanation**:
> - `left=%defaultroute`: StrongSwan automatically binds to the local network interface that reaches the internet.
> - `leftid=172.212.155.105`: The identifier matching your AWS Customer Gateway IP.
> - `leftsubnet=10.10.0.0/16`: The local on-premises network range to be encrypted.
> - `right=<AWS_TUNNEL_1_OUTSIDE_IP>`: The public IP address of AWS's VPN endpoint.
> - `rightsubnet=10.20.0.0/16`: The target AWS VPC network range.
> - `auto=start`: StrongSwan proactively initiates the connection to AWS.

---

### Step 2.4: Configure `/etc/ipsec.secrets`
This file stores the Pre-Shared Key (shared secret) used to authenticate both sides during IKE Phase 1.

Open the file:
```bash
sudo nano /etc/ipsec.secrets
```

Add the following line (replace `<AWS_TUNNEL_1_OUTSIDE_IP>` and `<YOUR_PRE_SHARED_KEY>` with your values):

```ini
# Format: <Local_Public_IP> <Remote_AWS_Tunnel_IP> : PSK "<Secret>"
172.212.155.105 <AWS_TUNNEL_1_OUTSIDE_IP> : PSK "<YOUR_PRE_SHARED_KEY>"
```

Lock down file permissions so only `root` can read the secret:
```bash
sudo chmod 600 /etc/ipsec.secrets
```

---

### Step 2.5: Configure Firewall & Packet Forwarding Rules
Ensure Linux `iptables` allows packets to be forwarded between the guest bridge `virbr1` and the external interface:

```bash
# Allow bidirectional forwarding between virbr1 (10.10.10.0/24) and the VPN
sudo iptables -A FORWARD -s 10.10.10.0/24 -d 10.20.0.0/16 -j ACCEPT
sudo iptables -A FORWARD -s 10.20.0.0/16 -d 10.10.10.0/24 -j ACCEPT

# Save iptables rules so they persist across reboots
sudo netfilter-persistent save 2>/dev/null || sudo iptables-save | sudo tee /etc/iptables/rules.v4
```

---

### Step 2.6: Start & Connect the IPsec Tunnel
Restart the StrongSwan daemon to read the new configuration and initiate the connection:

```bash
# Restart daemon
sudo ipsec restart

# Initiate connection
sudo ipsec up aws-tunnel-1
```

Expected terminal output:
```text
initiating IKE_SA aws-tunnel-1[1] to <AWS_TUNNEL_IP>
generating IKE_SA_INIT request 0
parsed IKE_SA_INIT response 0
authentication of '172.212.155.105' (myself) with pre-shared key
authentication of '<AWS_TUNNEL_IP>' with pre-shared key successful
IKE_SA aws-tunnel-1[1] established between 172.212.155.105...<AWS_TUNNEL_IP>
connection 'aws-tunnel-1' established successfully
```

---

## 4. Part 3: Verification & Deep Learning

### Step 3.1: Check Tunnel Status on `HV01`
Run:
```bash
sudo ipsec status
```
Expected output:
```text
Security Associations (1 up, 0 connecting):
aws-tunnel-1[1]: ESTABLISHED 2 minutes ago, 172.212.155.105...<AWS_TUNNEL_IP>
aws-tunnel-1{1}:  INSTALLED, TUNNEL, reqid 1, ESP in UDP SPIs: c74...
aws-tunnel-1{1}:   10.10.0.0/16 === 10.20.0.0/16
```

Run detailed status:
```bash
sudo ipsec statusall
```
This shows bytes in/out, rekey timers, and active encryption ciphers.

---

### Step 3.2: Inspect Encrypted IPsec ESP Packets
To see encryption happening in real-time, open a second terminal on `HV01` and run:

```bash
sudo tcpdump -n -i any esp or port 500 or port 4500
```
When you ping an AWS IP, you will see raw **ESP (Encapsulating Security Payload)** packets flowing across the interface!

---

### Step 3.3: End-to-End Cross-Cloud Ping Test
From one of your guest VMs (e.g., `APP01` at `10.10.10.20` or `DB01` at `10.10.10.30`):

```bash
# Ping a private IP inside AWS VPC (e.g., test instance in 10.20.10.x)
ping -c 4 <AWS_PRIVATE_IP>
```

Trace the path:
```bash
traceroute -n <AWS_PRIVATE_IP>
```
You will see:
1. First hop: `10.10.10.1` (`HV01` default gateway).
2. Second hop: Delivered directly into the AWS VPC private subnet over the VPN!

---

## 5. Troubleshooting Checklist

| Symptom | Probable Cause | Diagnostic Command & Fix |
| :--- | :--- | :--- |
| `NO_PROPOSAL_CHOSEN` | Cipher mismatch in Phase 1 / Phase 2 | Check `ike=` and `esp=` in `/etc/ipsec.conf`. Ensure `modp2048` is specified. |
| `AUTHENTICATION_FAILED` | Incorrect Pre-Shared Key | Verify `/etc/ipsec.secrets` exactly matches the AWS PSK. Check for whitespace or quotes. |
| `ipsec status` shows `ESTABLISHED`, but ping fails | AWS Route Propagation not enabled | Ensure VGW propagation is enabled on `streamflix-target-rt-app-private`. |
| Guest VMs cannot reach AWS | `net.ipv4.ip_forward` is 0 or IPTables drop | Check `sysctl net.ipv4.ip_forward` and verify `iptables -L FORWARD -v -n`. |
