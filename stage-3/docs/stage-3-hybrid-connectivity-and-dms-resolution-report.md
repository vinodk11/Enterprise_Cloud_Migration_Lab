# Stage 3: Hybrid Connectivity & AWS DMS Endpoints Resolution Report
**Document ID**: REPORT-STAGE3-CONNECTIVITY-DMS-RESOLUTION-20261105  
**Date**: November 5, 2026  
**Lab Context**: Enterprise Cloud Migration Lab (StreamFlix Application Suite)  
**Scope**: Site-to-Site VPN Tunnel, KVM Libvirt Networking, PostgreSQL Logical Replication, and AWS DMS Endpoint Connectivity  
**Status**: 100% RESOLVED & VERIFIED (`Both Endpoints: SUCCESSFUL`)  

---

## 1. Executive Summary & Verification Matrix

During the execution of **Stage 3 (Database Migration — AWS DMS with Change Data Capture / CDC)**, two primary errors prevented replication:
1. **Target RDS Endpoint Failure**: `FATAL: no pg_hba.conf entry for host "10.20.11.112", user "postgres", database "streamflix_db", no encryption`.
2. **Source DB01 Endpoint Failure**: `Failed to connect Network error has occurred ... timeout expired / Read timed out` followed by `password authentication failed for user "streamflix_user"`.

Through systematic end-to-end diagnosis across all layers of the hybrid architecture (AWS VPC Routing, IPsec Cryptography, KVM Virtual Bridge Firewalls, and PostgreSQL Internal Engine Configuration), all barriers were resolved.

### Final Verification State

```json
[
    {
        "Endpoint": "dms-source-db01",
        "Status": "successful",
        "LastFailure": null
    },
    {
        "Endpoint": "streamflix-target-db",
        "Status": "successful",
        "LastFailure": null
    }
]
```

---

## 2. Architectural Path & Layer Breakdown

The diagram below illustrates the end-to-end communication path between AWS DMS and on-premises PostgreSQL on `DB01`, indicating each layer that was diagnosed and rectified:

```
+-------------------------------------------------------------------------------------------------------------------------+
| AWS CLOUD (Target Landing Zone: 10.20.0.0/16)                                                                           |
|                                                                                                                         |
|  [AWS DMS Replication Instance] (10.20.11.112 in Subnet: streamflix-target-app-private-1b)                             |
|          |                                                                                                              |
|          |  [FIX 1: Target Endpoint SSL Enforcement]                                                                    |
|          +--------> Amazon RDS PostgreSQL (streamflix-target-db.cy9mak0su1oj.us-east-1.rds.amazonaws.com)               |
|          |          (SslMode changed from "none" to "require") -> Status: SUCCESSFUL                                    |
|          |                                                                                                              |
|          v                                                                                                              |
|  [VPC Route Table: rtb-04bf1704f096ed647]                                                                               |
|  [FIX 2: Added Static Route: 10.10.0.0/16 -> vgw-07ecf815eb50f71c3]                                                    |
|          |                                                                                                              |
|          v                                                                                                              |
|  [Virtual Private Gateway: vgw-07ecf815eb50f71c3]                                                                       |
|          |                                                                                                              |
|          v (IPsec VPN Tunnel 1: 100.57.28.164 <=====> 135.119.80.55)                                                   |
+----------|--------------------------------------------------------------------------------------------------------------+
           | (WAN Traversal over Encrypted Tunnel)
+----------|--------------------------------------------------------------------------------------------------------------+
| ON-PREMISES DATACENTER (Azure Edge Host: 10.10.1.10 / Public: 135.119.80.55)                                            |
|          |                                                                                                              |
|          v                                                                                                              |
|  [HV01 StrongSwan Daemon]                                                                                               |
|  [FIX 3: Phase 2 CHILD_SA Proposal Mismatch]                                                                            |
|  (Configured esp=aes256gcm16-sha256,aes256-sha256-modp2048... -> CHILD_SA INSTALLED)                                   |
|          |                                                                                                              |
|          v                                                                                                              |
|  [HV01 Kernel IP Forwarding & Libvirt Firewall]                                                                         |
|  [FIX 4: Allowed virbr10 FORWARD rules & bypassed NAT MASQUERADE for 10.20.0.0/16]                                      |
|          |                                                                                                              |
|          v (KVM Bridge: virbr10)                                                                                        |
|  [DB01 Guest VM: 10.10.10.30]                                                                                           |
|  [FIX 5: Started PostgreSQL 16 & set listen_addresses = '*']                                                           |
|  [FIX 6: Enabled wal_level = logical & max_replication_slots = 5]                                                       |
|  [FIX 7: Configured pg_hba.conf for 10.20.0.0/16 with scram-sha-256]                                                    |
|  [FIX 8: Synchronized streamflix_user password (StreamFlixPass2026!) with REPLICATION role]                             |
|          |                                                                                                              |
|          +--------> Result: Status: SUCCESSFUL                                                                          |
+-------------------------------------------------------------------------------------------------------------------------+
```

---

## 3. Step-by-Step Problem & Resolution Details

### Issue 1: Target RDS Endpoint SSL Rejection (`no encryption`)

* **Symptom**: Testing `streamflix-target-db` failed with:
  ```text
  FATAL: no pg_hba.conf entry for host "10.20.11.112", user "postgres", database "streamflix_db", no encryption
  ```
* **Root Cause**: Amazon RDS PostgreSQL enables `rds.force_ssl = 1` or enforces encrypted transport (`hostssl`) by default. When the target DMS endpoint was initially created, its SSL Mode was set to `none` (`no encryption`), causing PostgreSQL's access control to drop the unencrypted connection.
* **Resolution**: Modified the target endpoint to enforce TLS/SSL transport:
  ```bash
  aws dms modify-endpoint \
    --endpoint-arn arn:aws:dms:us-east-1:165772574557:endpoint:3NDWVUAJ5NCWBEGMLQCK2MZ6LY \
    --ssl-mode require
  ```
* **Verification**: Immediate re-test transitioned `streamflix-target-db` to **`successful`**.

---

### Issue 2: AWS VPC Routing Missing Static Route to On-Premises

* **Symptom**: Testing `dms-source-db01` resulted in `timeout expired / Read timed out`.
* **Root Cause**: While route propagation was enabled on the VPC route tables, the static route `10.10.0.0/16` targeting `vgw-07ecf815eb50f71c3` was missing from route table `rtb-04bf1704f096ed647` (the private subnet where the DMS replication instance was running). Packets from DMS had no route back to `10.10.0.0/16`.
* **Resolution**: Injected explicit static routes into all target route tables:
  ```bash
  aws ec2 create-route --route-table-id rtb-04bf1704f096ed647 --destination-cidr-block 10.10.0.0/16 --gateway-id vgw-07ecf815eb50f71c3
  aws ec2 create-route --route-table-id rtb-07e092645eb1b032a --destination-cidr-block 10.10.0.0/16 --gateway-id vgw-07ecf815eb50f71c3
  aws ec2 create-route --route-table-id rtb-0baf7237f832568b4 --destination-cidr-block 10.10.0.0/16 --gateway-id vgw-07ecf815eb50f71c3
  ```

---

### Issue 3: StrongSwan Phase 2 (CHILD_SA) `NO_PROPOSAL_CHOSEN` Mismatch

* **Symptom**: `sudo ipsec statusall` on `HV01` showed Phase 1 (IKE_SA) `ESTABLISHED`, but **no CHILD_SA was installed**. When triggering `sudo ipsec up aws-tunnel-1`, StrongSwan reported:
  ```text
  parsed CREATE_CHILD_SA response 55 [ N(NO_PROP) ]
  received NO_PROPOSAL_CHOSEN notify, no CHILD_SA built
  failed to establish CHILD_SA, keeping IKE_SA
  ```
* **Root Cause**: AWS VPN endpoints require a Diffie-Hellman Perfect Forward Secrecy (PFS) proposal for Phase 2 (e.g. `modp2048` / DH Group 14 or `modp1024` / DH Group 2). The local `/etc/ipsec.conf` file defined `esp=aes256gcm16-sha256,aes256-sha256!` without DH parameters, causing AWS to reject the child security association.
* **Resolution**: Updated the ESP proposal in `/etc/ipsec.conf` on `HV01`:
  ```ini
  esp=aes256gcm16-sha256,aes256-sha256-modp2048,aes256-sha256,aes128-sha1-modp1024,aes128-sha1!
  ```
  Restarted StrongSwan:
  ```bash
  sudo systemctl restart strongswan-starter
  sudo ipsec status
  ```
* **Verification**: StrongSwan immediately installed the child SA:
  ```text
  aws-tunnel-1{1}:  INSTALLED, TUNNEL, reqid 1, ESP in UDP
  aws-tunnel-1{1}:   10.10.0.0/16 === 10.20.0.0/16
  ```

---

### Issue 4: KVM Libvirt Firewall Dropping Incoming Traffic to DB01

* **Symptom**: Decrypted packets arriving at `HV01` destined for `10.10.10.30` were not reaching `DB01`.
* **Root Cause**: By default, `libvirt` installs isolation rules in Linux iptables:
  `-A FORWARD -o virbr10 -j REJECT --reject-with icmp-port-unreachable`
  This drops new incoming connections arriving from external interfaces (`eth0` / IPsec) into virtual machines on `virbr10`. Additionally, libvirt's NAT engine masquerades guest IP addresses.
* **Resolution**: Added iptables rules to permit bidirectional forwarding and bypass NAT for traffic traversing the AWS VPN:
  ```bash
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo iptables -I FORWARD 1 -d 10.10.10.0/24 -o virbr10 -j ACCEPT
  sudo iptables -I FORWARD 1 -s 10.10.10.0/24 -i virbr10 -j ACCEPT
  sudo iptables -t nat -I POSTROUTING 1 -s 10.10.10.0/24 -d 10.20.0.0/16 -j ACCEPT
  ```

---

### Issue 5: PostgreSQL Localhost Binding on DB01

* **Symptom**: Remote connection attempts timed out, and local `psql` returned:
  ```text
  connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: No such file or directory
  ```
* **Root Cause**: PostgreSQL was stopped following the Azure VM deallocation/reboot. Additionally, the default PostgreSQL configuration only listens on `localhost` (`127.0.0.1`), ignoring requests on `10.10.10.30`.
* **Resolution**:
  1. Started PostgreSQL:
     ```bash
     sudo systemctl start postgresql
     ```
  2. Updated `postgresql.conf` to bind to all interfaces:
     ```ini
     listen_addresses = '*'
     ```
  3. Verified binding with `ss -tulpn | grep 5432` (`tcp LISTEN 0 200 0.0.0.0:5432`).

---

### Issue 6: Logical Replication & SCRAM-SHA-256 Authentication Mismatch

* **Symptom**: AWS DMS reached port 5432 on `DB01`, but failed with:
  ```text
  FATAL: password authentication failed for user "streamflix_user"
  ```
* **Root Cause**:
  1. PostgreSQL 16 stores user credentials using the modern `scram-sha-256` hashing algorithm.
  2. The added line in `pg_hba.conf` specified `md5` (`host all all 10.20.0.0/16 md5`). When PostgreSQL receives a client matching an `md5` line, it cannot verify the password against a SCRAM-SHA-256 hash.
  3. `streamflix_user` required explicit `REPLICATION` permissions to support Change Data Capture (CDC).
* **Resolution**:
  1. Enabled logical replication parameters in `/etc/postgresql/16/main/postgresql.conf`:
     ```ini
     wal_level = logical
     max_replication_slots = 5
     max_wal_senders = 5
     ```
  2. Updated `/etc/postgresql/16/main/pg_hba.conf` to use `scram-sha-256`:
     ```text
     host    all             all             10.20.0.0/16            scram-sha-256
     host    replication     all             10.20.0.0/16            scram-sha-256
     ```
  3. Synchronized password and permissions in PostgreSQL:
     ```sql
     ALTER USER streamflix_user WITH REPLICATION;
     ALTER USER streamflix_user WITH PASSWORD 'StreamFlixPass2026!';
     GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO streamflix_user;
     ```
  4. Aligned the password on the AWS DMS source endpoint:
     ```bash
     aws dms modify-endpoint \
       --endpoint-arn arn:aws:dms:us-east-1:165772574557:endpoint:AWXAALGFUZDTZPSAVA72ITNZNM \
       --password StreamFlixPass2026!
     ```

---

## 4. Final Verification Results

Running `aws dms describe-connections`:

```json
[
    {
        "Endpoint": "streamflix-target-db",
        "Status": "successful",
        "LastFailure": null
    },
    {
        "Endpoint": "dms-source-db01",
        "Status": "successful",
        "LastFailure": null
    }
]
```

* **VPN Tunnel 1**: `UP` (`100.57.28.164 <-> 135.119.80.55`)
* **Source PostgreSQL CDC Status**: `wal_level = logical`
* **Target RDS PostgreSQL Status**: `available` (`PostgreSQL 16.3`, SSL enforced)
* **Replication Readiness**: 100% verified and operational.

---

## 5. Next Action: Execute AWS DMS Migration Task

With both endpoints validated, the final operational step is launching the continuous CDC replication task `dms-task-streamflix-cdc`:

```bash
aws dms create-replication-task \
  --replication-task-identifier dms-task-streamflix-cdc \
  --source-endpoint-arn arn:aws:dms:us-east-1:165772574557:endpoint:AWXAALGFUZDTZPSAVA72ITNZNM \
  --target-endpoint-arn arn:aws:dms:us-east-1:165772574557:endpoint:3NDWVUAJ5NCWBEGMLQCK2MZ6LY \
  --replication-instance-arn arn:aws:dms:us-east-1:165772574557:rep:D7EV7UK6XNDLDFQJ3QLHZRAIDQ \
  --migration-type full-load-and-cdc \
  --table-mappings '{"rules":[{"rule-type":"selection","rule-id":"1","rule-name":"include-all","object-locator":{"schema-name":"public","table-name":"%"},"rule-action":"include"}]}' \
  --start-replication-task-type start-replication
```
